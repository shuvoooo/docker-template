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
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --user --no-warn-script-location -r requirements.txt
RUN pip install --user --no-warn-script-location gunicorn


# ── Final Stage ─────────────────────────────
FROM builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/root/.local/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    postgresql-client \
    libpq5 \
    curl \
    netcat-openbsd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /root/.local /root/.local

WORKDIR /app

COPY . .

RUN mkdir -p /app/static /app/staticfiles /app/media \
             /app/logs /var/log/nginx /var/lib/nginx /run

# ── Nginx config ──────────────────────────────────────────────────────────────
# Logs are written to /dev/stdout and /dev/stderr so that `docker logs` shows

COPY <<'EOF'  /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
daemon off;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;

    access_log /dev/stdout;
    error_log  /dev/stderr warn;

    server {
        listen 80;
        server_name _;
        client_max_body_size 100M;

        location /static/ {
            alias /app/static/;
            expires 30d;
            add_header Cache-Control "public, immutable";
        }

        location /media/ {
            alias /app/media/;
            expires 7d;
            autoindex on;
            add_header Cache-Control "public";
        }

        location / {
            proxy_pass http://127.0.0.1:8000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_redirect off;
            proxy_connect_timeout 75s;
            proxy_send_timeout 75s;
            proxy_read_timeout 75s;
        }
    }
}
EOF


# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY <<'EOF'  /app/docker-entrypoint.sh
#!/bin/bash
set -e

echo "============================================"
echo " Lake Forest – container startup"
echo "============================================"

# ── 1. Collect static files ──────────────────────────────────────────────────
echo "[1/4] Running collectstatic..."
python manage.py collectstatic --noinput 2>&1 || {
    echo "WARNING: collectstatic failed (check STATIC_ROOT / env vars). Continuing..."
}

# ── 2. Run DB migrations ─────────────────────────────────────────────────────
echo "[2/4] Running database migrations..."
python manage.py migrate --noinput 2>&1 || {
    echo "WARNING: migrate failed (DB might not be reachable yet). Continuing..."
}

# ── 3. Start Gunicorn in the background (NOT as a daemon) ────────────────────
# --log-file - and --access-logfile - route all output to stdout/stderr so
# that `docker logs` picks them up.
echo "[3/4] Starting Gunicorn on 127.0.0.1:8000..."
gunicorn lake_forest.wsgi:application \
    --bind 127.0.0.1:8000 \
    --workers "${GUNICORN_WORKERS:-4}" \
    --threads "${GUNICORN_THREADS:-2}" \
    --timeout "${GUNICORN_TIMEOUT:-120}" \
    --log-level "${GUNICORN_LOG_LEVEL:-info}" \
    --log-file - \
    --access-logfile - \
    --capture-output \
    &
GUNICORN_PID=$!
echo "  → Gunicorn PID: $GUNICORN_PID"

# ── 4. Wait until Gunicorn is actually accepting connections ──────────────────
echo "[4/4] Waiting for Gunicorn to bind to port 8000..."
MAX_WAIT=60
WAITED=0
until nc -z 127.0.0.1 8000; do
    # Bail early if Gunicorn already died (misconfiguration, import error, etc.)
    if ! kill -0 "$GUNICORN_PID" 2>/dev/null; then
        echo "ERROR: Gunicorn process exited prematurely. Check the logs above for details."
        exit 1
    fi
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        echo "ERROR: Gunicorn did not become ready within ${MAX_WAIT}s."
        kill "$GUNICORN_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
    echo "  → waited ${WAITED}s..."
done
echo "  → Gunicorn is ready (took ${WAITED}s)."

# ── 5. Start Nginx ────────────────────────────────────────────────────────────
# nginx.conf has `daemon off;`, so the process stays in the foreground.
echo "Starting Nginx..."

# Graceful shutdown handler
_shutdown() {
    echo "Caught signal – shutting down gracefully..."
    kill "$NGINX_PID"   2>/dev/null || true
    kill "$GUNICORN_PID" 2>/dev/null || true
    wait "$NGINX_PID"   2>/dev/null || true
    wait "$GUNICORN_PID" 2>/dev/null || true
    exit 0
}
trap _shutdown SIGTERM SIGINT

nginx &
NGINX_PID=$!
echo "  → Nginx PID: $NGINX_PID"

# ── 6. Monitor both processes ─────────────────────────────────────────────────
# `wait -n` returns as soon as ANY child exits; we then figure out which one.
while true; do
    wait -n "$GUNICORN_PID" "$NGINX_PID" 2>/dev/null
    EXIT_CODE=$?

    if ! kill -0 "$GUNICORN_PID" 2>/dev/null; then
        echo "ERROR: Gunicorn (PID $GUNICORN_PID) exited with code $EXIT_CODE. Stopping container."
        kill "$NGINX_PID" 2>/dev/null || true
        exit 1
    fi

    if ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "ERROR: Nginx (PID $NGINX_PID) exited with code $EXIT_CODE. Stopping container."
        kill "$GUNICORN_PID" 2>/dev/null || true
        exit 1
    fi
done
EOF

RUN chmod +x /app/docker-entrypoint.sh

# ── Permissions ───────────────────────────────────────────────────────────────
RUN chown -R www-data:www-data /app/static /app/staticfiles /app/media /app/logs

VOLUME ["/app/media", "/app/staticfiles", "/app/logs"]

EXPOSE 80

# Health-check: allow 90 s for startup (collectstatic + migrate + gunicorn init)
HEALTHCHECK --interval=15s --timeout=10s --start-period=90s --retries=5 \
    CMD curl -sf http://localhost:80/ || exit 1

CMD ["/bin/bash", "/app/docker-entrypoint.sh"]
