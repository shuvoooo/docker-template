FROM python:3.10-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    postgresql-client \
    libpq5 \
    libmariadb3  \
    default-libmysqlclient-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --user --no-warn-script-location -r requirements.txt
RUN pip install --user --no-warn-script-location gunicorn
# ============================================
# Final Stage
# ============================================
FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/root/.local/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    postgresql-client \
    libpq5 \
    default-mysql-client \
    libmariadb3  \
    curl \
    netcat-openbsd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /root/.local /root/.local

WORKDIR /app

COPY . .

RUN mkdir -p /app/static /app/staticfiles /app/media /app/logs /var/log/nginx /var/lib/nginx /run

# Configure Nginx
RUN echo 'user www-data;\n\
worker_processes auto;\n\
pid /run/nginx.pid;\n\
daemon off;\n\
\n\
events {\n\
    worker_connections 1024;\n\
}\n\
\n\
http {\n\
    include /etc/nginx/mime.types;\n\
    default_type application/octet-stream;\n\
    \n\
    sendfile on;\n\
    tcp_nopush on;\n\
    keepalive_timeout 65;\n\
    \n\
    access_log /app/logs/nginx_access.log;\n\
    error_log /app/logs/nginx_error.log;\n\
    \n\
    server {\n\
        listen 80;\n\
        server_name _;\n\
        client_max_body_size 100M;\n\
        \n\
        location /static/ {\n\
            alias /app/staticfiles/;\n\
            expires 30d;\n\
            add_header Cache-Control "public, immutable";\n\
        }\n\
        \n\
        location /media/ {\n\
            alias /app/media/;\n\
            expires 7d;\n\
            autoindex on;\n\
            add_header Cache-Control "public";\n\
        }\n\
        \n\
        location / {\n\
            proxy_pass http://127.0.0.1:8000;\n\
            proxy_set_header Host $host;\n\
            proxy_set_header X-Real-IP $remote_addr;\n\
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n\
            proxy_set_header X-Forwarded-Proto $scheme;\n\
            proxy_redirect off;\n\
            proxy_connect_timeout 60s;\n\
            proxy_send_timeout 60s;\n\
            proxy_read_timeout 60s;\n\
        }\n\
    }\n\
}\n' > /etc/nginx/nginx.conf

# Create startup script with proper error handling
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
echo "Starting Gunicorn in background..."\n\
gunicorn fervent.wsgi:application \\\n\
    --bind 127.0.0.1:8000 \\\n\
    --workers 4 \\\n\
    --threads 2 \\\n\
    --timeout 60 \\\n\
    --access-logfile /app/logs/gunicorn_access.log \\\n\
    --error-logfile /app/logs/gunicorn_error.log \\\n\
    --log-level info \\\n\
    --daemon\n\
\n\
echo "Waiting for Gunicorn to start..."\n\
sleep 3\n\
\n\
echo "Starting Nginx..."\n\
exec nginx\n' > /app/start.sh

RUN chmod +x /app/start.sh

# Set proper permissions
RUN chown -R www-data:www-data /app/static /app/staticfiles /app/media /app/logs

# Declare volumes for persistent data
VOLUME ["/app/media", "/app/staticfiles", "/app/logs"]

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:80/ || exit 1

CMD ["/app/start.sh"]
