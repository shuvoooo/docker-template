# ============================================================
# Multi-stage singleton Dockerfile for Django (WSGI)
# Static: /app/static | Media: /app/media
# Stack: Python 3.12 + Gunicorn + Nginx (supervisor managed)
# ============================================================

# ── Stage 1: Build dependencies ─────────────────────────────
FROM python:3.10-slim AS builder

WORKDIR /build

# Install build-only system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --upgrade pip \
 && pip install --prefix=/install --no-cache-dir -r requirements.txt


# ── Stage 2: Runtime image ──────────────────────────────────
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DJANGO_SETTINGS_MODULE=config.settings \
    APP_HOME=/app

# Runtime system packages: nginx + supervisor (no build tools)
RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx \
        supervisor \
        libpq5 \
        curl \
    && rm -rf /var/lib/apt/lists/* \
    # Remove the default nginx site
    && rm -f /etc/nginx/sites-enabled/default

# Copy installed Python packages from builder
COPY --from=builder /install /usr/local

WORKDIR $APP_HOME

# Copy project source
COPY . .

# Create non-root user
RUN groupadd --gid 1001 django \
 && useradd  --uid 1001 --gid django --shell /bin/bash --create-home django \
 # Media & static dirs with correct ownership
 && mkdir -p /app/static /app/media \
 && chown -R django:django /app \
 # Nginx needs to write its pid/logs, supervisor needs /var/run
 && chown -R django:django /var/log/nginx /var/lib/nginx \
 && touch /var/run/nginx.pid && chown django:django /var/run/nginx.pid

# ── Nginx configuration ─────────────────────────────────────
RUN cat > /etc/nginx/nginx.conf << 'NGINX_CONF'
user django;
worker_processes auto;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile           on;
    tcp_nopush         on;
    tcp_nodelay        on;
    keepalive_timeout  65;
    client_max_body_size 50M;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript
               image/svg+xml;

    # Security headers
    add_header X-Frame-Options           SAMEORIGIN;
    add_header X-Content-Type-Options    nosniff;
    add_header X-XSS-Protection          "1; mode=block";
    add_header Referrer-Policy           "strict-origin-when-cross-origin";

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main;

    upstream gunicorn {
        server unix:/tmp/gunicorn.sock fail_timeout=0;
    }

    server {
        listen 80;
        server_name _;

        # Static files — served directly by nginx
        location /static/ {
            alias /app/static/;
            expires 30d;
            add_header Cache-Control "public, immutable";
            access_log off;
        }

        # Media files — served directly by nginx
        location /media/ {
            alias /app/media/;
            expires 7d;
            add_header Cache-Control "public";
            access_log off;
        }

        # Everything else → Gunicorn
        location / {
            proxy_pass         http://gunicorn;
            proxy_set_header   Host              $http_host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            proxy_redirect     off;
            proxy_read_timeout 120s;
            proxy_connect_timeout 10s;

            # Buffer settings
            proxy_buffering    on;
            proxy_buffer_size  16k;
            proxy_buffers      8 16k;
        }

        # Health-check endpoint (no upstream hit)
        location /healthz {
            access_log off;
            return 200 "ok\n";
            add_header Content-Type text/plain;
        }
    }
}
NGINX_CONF

# ── Supervisor configuration ─────────────────────────────────
RUN cat > /etc/supervisor/conf.d/app.conf << 'SUPERVISOR_CONF'
[supervisord]
nodaemon=true
user=django
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
loglevel=info

[program:gunicorn]
command=/usr/local/bin/gunicorn
    --bind unix:/tmp/gunicorn.sock
    --workers %(ENV_GUNICORN_WORKERS)s
    --threads %(ENV_GUNICORN_THREADS)s
    --worker-class gthread
    --worker-tmp-dir /dev/shm
    --timeout 120
    --keep-alive 5
    --max-requests 1000
    --max-requests-jitter 100
    --access-logfile -
    --error-logfile -
    --log-level info
    config.wsgi:application
directory=/app
user=django
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
startsecs=3
stopwaitsecs=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
SUPERVISOR_CONF

RUN mkdir -p /var/log/supervisor \
 && chown -R django:django /var/log/supervisor

# ── Entrypoint ───────────────────────────────────────────────
RUN cat > /app/entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
set -e

echo "==> Collecting static files..."
python manage.py collectstatic --noinput --clear

echo "==> Applying database migrations..."
python manage.py migrate --noinput

echo "==> Starting services..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
ENTRYPOINT

RUN chmod +x /app/entrypoint.sh && chown django:django /app/entrypoint.sh

# ── Final ────────────────────────────────────────────────────
USER django

EXPOSE 80

# Tunable at runtime via -e flags
ENV GUNICORN_WORKERS=4 \
    GUNICORN_THREADS=2

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -fs http://localhost/healthz || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
