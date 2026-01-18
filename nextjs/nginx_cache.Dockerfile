# syntax=docker.io/docker/dockerfile:1

FROM node:20-alpine AS base
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable

# Dependencies stage with cache optimization
FROM base AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app

COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* .npmrc* ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
  if [ -f yarn.lock ]; then yarn --frozen-lockfile --production=false; \
  elif [ -f package-lock.json ]; then npm ci --prefer-offline --no-audit; \
  elif [ -f pnpm-lock.yaml ]; then pnpm i --frozen-lockfile; \
  else echo "Lockfile not found." && exit 1; \
  fi

# Production dependencies only
FROM base AS prod-deps
RUN apk add --no-cache libc6-compat
WORKDIR /app

COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* .npmrc* ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
  if [ -f yarn.lock ]; then yarn --frozen-lockfile --production; \
  elif [ -f package-lock.json ]; then npm ci --only=production --prefer-offline --no-audit; \
  elif [ -f pnpm-lock.yaml ]; then pnpm i --prod --frozen-lockfile; \
  else echo "Lockfile not found." && exit 1; \
  fi

# Builder stage
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production

RUN \
  if [ -f yarn.lock ]; then yarn run build; \
  elif [ -f package-lock.json ]; then npm run build; \
  elif [ -f pnpm-lock.yaml ]; then pnpm run build; \
  else echo "Lockfile not found." && exit 1; \
  fi && \
  # Remove source maps to save space
  find .next -name "*.map" -type f -delete && \
  # Remove unnecessary files
  rm -rf .next/cache

# Ultra-minimal production stage
FROM alpine:3.19 AS runner
WORKDIR /app

# Install only essential runtime dependencies
RUN apk add --no-cache \
    nodejs \
    nginx \
    supervisor \
    curl \
    tzdata \
    ca-certificates && \
    # Clean apk cache
    rm -rf /var/cache/apk/* /tmp/* && \
    # Create necessary directories
    mkdir -p /var/cache/nginx/nextjs \
        /var/log/nginx \
        /var/log/supervisor \
        /run/nginx \
        /etc/supervisor/conf.d && \
    # Create users
    addgroup -g 1001 -S nodejs && \
    adduser -S nextjs -u 1001 -G nodejs

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    NODE_OPTIONS="--max-old-space-size=2048" \
    PORT=3000 \
    HOSTNAME="127.0.0.1"

# Copy only production node_modules (much smaller)
COPY --from=prod-deps --chown=nextjs:nodejs /app/node_modules ./node_modules

# Copy only necessary Next.js files
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public ./public

# Optimized Nginx configuration
RUN cat > /etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
worker_cpu_affinity auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent"';

    access_log /var/log/nginx/access.log main buffer=16k;

    # Performance
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 100;
    reset_timedout_connection on;
    client_body_timeout 10;
    send_timeout 10;
    client_max_body_size 20M;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_comp_level 6;
    gzip_min_length 1000;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml text/javascript 
               application/json application/javascript application/xml+rss 
               application/x-font-ttf image/svg+xml;
    gzip_disable "msie6";

    # Cache
    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    proxy_cache_path /var/cache/nginx/nextjs levels=1:2 
                     keys_zone=nextjs_cache:10m max_size=500m 
                     inactive=60m use_temp_path=off;

    upstream nextjs_backend {
        server 127.0.0.1:3000;
        keepalive 32;
    }

    server {
        listen 80 default_server;
        server_name _;
        server_tokens off;

        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;

        # Static assets
        location ~* \.(jpg|jpeg|png|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|css|js)$ {
            root /app/public;
            expires 1y;
            add_header Cache-Control "public, immutable";
            access_log off;
            try_files $uri =404;
        }

        location /_next/static/ {
            alias /app/.next/static/;
            expires 1y;
            add_header Cache-Control "public, immutable";
            access_log off;
        }

        location /_next/image {
            proxy_pass http://nextjs_backend;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_cache nextjs_cache;
            proxy_cache_valid 200 60m;
            proxy_cache_key "$scheme$request_method$host$request_uri";
            add_header X-Cache-Status $upstream_cache_status;
        }

        location / {
            proxy_pass http://nextjs_backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_cache_bypass $http_upgrade;
            proxy_buffering on;
            proxy_buffer_size 4k;
            proxy_buffers 8 4k;
        }
    }
}
EOF

# Minimal supervisor config
RUN cat > /etc/supervisor/conf.d/supervisord.conf <<'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/dev/null
logfile_maxbytes=0
pidfile=/var/run/supervisord.pid

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=10

[program:nextjs]
command=/usr/bin/node server.js
directory=/app
user=nextjs
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=20
environment=NODE_ENV="production",PORT="3000",HOSTNAME="127.0.0.1"
EOF

# Set permissions and cleanup
RUN chown -R nextjs:nodejs /app && \
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx /run/nginx && \
    chmod -R 755 /var/cache/nginx && \
    # Remove unnecessary files
    rm -rf /usr/share/man/* \
           /usr/share/doc/* \
           /var/cache/apk/* \
           /tmp/* \
           /var/tmp/* && \
    # Strip binaries to reduce size
    find /usr/local/bin /usr/bin -type f -exec strip --strip-all {} \; 2>/dev/null || true

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD curl -f http://localhost/ || exit 1

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
