# =================================================================
# Single-File Production Dockerfile – Django WSGI
# Stack : Python 3.12-slim · Gunicorn · Nginx · Supervisord
# Static: /static  |  Media: /media  |  Port: 80
# =================================================================

FROM python:3.12-slim

# ── Build-time args ───────────────────────────────────────────────
ARG DJANGO_SETTINGS_MODULE=config.settings.production
ARG APP_HOME=/app

# ── Runtime environment ───────────────────────────────────────────
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONFAULTHANDLER=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE} \
    APP_HOME=${APP_HOME}

# ── System packages ───────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx \
        supervisor \
        curl \
        libpq5 \
        libjpeg62-turbo \
    && rm -rf /var/lib/apt/lists/*

# ── Non-root app user ─────────────────────────────────────────────
RUN groupadd --gid 1000 django \
    && useradd  --uid 1000 --gid django --shell /bin/bash --create-home django \
    && usermod  -aG www-data django

# ── Python deps ───────────────────────────────────────────────────
WORKDIR ${APP_HOME}

COPY requirements.txt .

RUN pip install --upgrade pip \
    && pip install gunicorn==22.0.0 psycopg2-binary==2.9.9 \
    && pip install -r requirements.txt

# ── Application source ────────────────────────────────────────────
COPY --chown=django:django . ${APP_HOME}

# ── Volume mount-points ───────────────────────────────────────────
RUN mkdir -p /static /media \
    && chown -R django:django /static /media ${APP_HOME}

# ── Collect static at build time ──────────────────────────────────
RUN SECRET_KEY=build-placeholder \
    python manage.py collectstatic --noinput --clear

# =================================================================
# NGINX CONFIG (written inline – no external file needed)
# =================================================================
RUN printf '%s\n' \
'user www-data;' \
'worker_processes auto;' \
'pid /run/nginx.pid;' \
'error_log /dev/stderr warn;' \
'' \
'events {' \
'    worker_connections 1024;' \
'    use epoll;' \
'    multi_accept on;' \
'}' \
'' \
'http {' \
'    include       /etc/nginx/mime.types;' \
'    default_type  application/octet-stream;' \
'    access_log    /dev/stdout combined;' \
'' \
'    sendfile        on;' \
'    tcp_nopush      on;' \
'    tcp_nodelay     on;' \
'    keepalive_timeout 65;' \
'    server_tokens   off;' \
'    client_max_body_size 50M;' \
'' \
'    gzip on;' \
'    gzip_vary on;' \
'    gzip_proxied any;' \
'    gzip_comp_level 6;' \
'    gzip_types text/plain text/css application/json application/javascript' \
'               text/xml application/xml image/svg+xml font/woff2;' \
'' \
'    upstream gunicorn {' \
'        server unix:/run/gunicorn.sock fail_timeout=0;' \
'    }' \
'' \
'    server {' \
'        listen 80 default_server;' \
'        server_name _;' \
'' \
'        location /static/ {' \
'            alias /static/;' \
'            expires 30d;' \
'            add_header Cache-Control "public, immutable";' \
'            access_log off;' \
'        }' \
'' \
'        location /media/ {' \
'            alias /media/;' \
'            expires 7d;' \
'            add_header Cache-Control "public";' \
'            access_log off;' \
'        }' \
'' \
'        location / {' \
'            proxy_pass          http://gunicorn;' \
'            proxy_set_header    Host              $http_host;' \
'            proxy_set_header    X-Real-IP         $remote_addr;' \
'            proxy_set_header    X-Forwarded-For   $proxy_add_x_forwarded_for;' \
'            proxy_set_header    X-Forwarded-Proto $scheme;' \
'            proxy_redirect      off;' \
'            proxy_connect_timeout 60s;' \
'            proxy_read_timeout    120s;' \
'            proxy_send_timeout    60s;' \
'        }' \
'    }' \
'}' \
> /etc/nginx/nginx.conf \
    && rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

# =================================================================
# GUNICORN CONFIG (written inline)
# =================================================================
RUN printf '%s\n' \
'import multiprocessing, os' \
'' \
'bind             = "unix:/run/gunicorn.sock"' \
'workers          = int(os.getenv("GUNICORN_WORKERS", multiprocessing.cpu_count() * 2 + 1))' \
'worker_class     = "sync"' \
'threads          = int(os.getenv("GUNICORN_THREADS", 2))' \
'timeout          = int(os.getenv("GUNICORN_TIMEOUT", 120))' \
'graceful_timeout = 30' \
'keepalive        = 5' \
'accesslog        = "-"' \
'errorlog         = "-"' \
'loglevel         = os.getenv("GUNICORN_LOG_LEVEL", "info")' \
'access_log_format = "%(h)s %(l)s %(u)s %(t)s %(r)s %(s)s %(b)s %(D)sus"' \
'proc_name        = "django"' \
'umask            = 0o117' \
> /etc/gunicorn.conf.py

# =================================================================
# SUPERVISORD CONFIG (written inline)
# =================================================================
RUN printf '%s\n' \
'[supervisord]' \
'nodaemon=true' \
'user=root' \
'logfile=/dev/null' \
'logfile_maxbytes=0' \
'pidfile=/run/supervisord.pid' \
'' \
'[program:gunicorn]' \
'command=gunicorn --config /etc/gunicorn.conf.py %(ENV_DJANGO_WSGI_APP)s' \
'directory=/app' \
'user=django' \
'autostart=true' \
'autorestart=true' \
'startretries=5' \
'stopwaitsecs=30' \
'stopsignal=TERM' \
'stdout_logfile=/dev/stdout' \
'stdout_logfile_maxbytes=0' \
'stderr_logfile=/dev/stderr' \
'stderr_logfile_maxbytes=0' \
'' \
'[program:nginx]' \
'command=/usr/sbin/nginx -g "daemon off;"' \
'autostart=true' \
'autorestart=true' \
'startretries=5' \
'stdout_logfile=/dev/stdout' \
'stdout_logfile_maxbytes=0' \
'stderr_logfile=/dev/stderr' \
'stderr_logfile_maxbytes=0' \
> /etc/supervisor/conf.d/app.conf

# =================================================================
# ENTRYPOINT (written inline)
# =================================================================
RUN printf '%s\n' \
'#!/bin/bash' \
'set -euo pipefail' \
'' \
'log() { echo "[entrypoint] $*"; }' \
'' \
'# Socket dir: writable by django (gunicorn) and www-data (nginx)' \
'mkdir -p /run' \
'chown root:www-data /run' \
'chmod 775 /run' \
'' \
'# Wait for database (skip if DATABASE_HOST not set)' \
'if [[ -n "${DATABASE_HOST:-}" ]]; then' \
'    log "Waiting for database ${DATABASE_HOST}:${DATABASE_PORT:-5432} ..."' \
'    until python -c "' \
'import socket, sys' \
'try:' \
'    socket.create_connection((\"${DATABASE_HOST}\", int(\"${DATABASE_PORT:-5432}\")), 2).close()' \
'except OSError:' \
'    sys.exit(1)' \
'" 2>/dev/null; do' \
'        log "  not ready - retrying in 2s"' \
'        sleep 2' \
'    done' \
'    log "Database ready."' \
'fi' \
'' \
'log "Running migrate ..."' \
'su -s /bin/bash django -c "python /app/manage.py migrate --noinput"' \
'' \
'log "Fixing ownership ..."' \
'chown -R django:django /media /static' \
'' \
'log "Starting supervisord ..."' \
'exec "$@"' \
> /entrypoint.sh && chmod +x /entrypoint.sh

# ── Expose & health ───────────────────────────────────────────────
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

# Override DJANGO_WSGI_APP to match your project module, e.g.:
#   docker run -e DJANGO_WSGI_APP=myproject.wsgi:application ...
ENV DJANGO_WSGI_APP=config.wsgi:application

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/conf.d/app.conf"]
