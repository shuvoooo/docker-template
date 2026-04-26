FROM php:8.3-fpm AS builder

# Stage 1: builder — includes Node.js, yarn, build tools, and Composer for optimised vendor/ and public/build/
WORKDIR /var/www/html

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl \
    libonig-dev libxml2-dev \
    libpng-dev libjpeg-dev libfreetype6-dev \
    libzip-dev zip unzip \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) pdo_mysql mbstring exif pcntl bcmath gd zip \
    && npm install -g yarn \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader --no-interaction --no-scripts --no-autoloader


COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

COPY . .
RUN composer dump-autoload --optimize --classmap-authoritative \
    && yarn build \
    && yarn cache clean \
    && rm -rf node_modules

# Stage 2: final — runtime only, no Node.js/yarn/build tools
FROM php:8.3-fpm AS final

WORKDIR /var/www/html

RUN apt-get update && apt-get install -y --no-install-recommends \
    libonig-dev libxml2-dev \
    libpng-dev libjpeg-dev libfreetype6-dev \
    libzip-dev \
    nginx supervisor \
    weasyprint \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) pdo_mysql mbstring exif pcntl bcmath gd zip \
    && apt-get purge -y libonig-dev libxml2-dev libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --chown=www-data:www-data . .
COPY --from=builder --chown=www-data:www-data /var/www/html/vendor ./vendor/
COPY --from=builder --chown=www-data:www-data /var/www/html/public/build ./public/build/

RUN mkdir -p storage/framework/{sessions,views,cache} storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache \
    && rm -f .env

# Nginx configuration
COPY <<'EOF' /etc/nginx/sites-available/default
server {
    listen 80;
    listen [::]:80;
    server_name localhost;
    root /var/www/html/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;
    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        # Forward the scheme set by the upstream TLS-terminating proxy
        fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
        fastcgi_param HTTP_X_FORWARDED_FOR   $http_x_forwarded_for;
        include fastcgi_params;
        fastcgi_read_timeout 120s;
        fastcgi_send_timeout 120s;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 256 16k;
        fastcgi_busy_buffers_size 256k;
        fastcgi_temp_file_write_size 256k;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

# Supervisor configuration
COPY <<'EOF' /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:php-fpm]
command=/usr/local/sbin/php-fpm -F
autostart=true
autorestart=true
priority=5
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:laravel-scheduler]
process_name=%(program_name)s
command=/bin/sh -c "while true; do php /var/www/html/artisan schedule:run --verbose --no-interaction; sleep 60; done"
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/scheduler.log

[program:laravel-queue]
process_name=%(program_name)s
command=php /var/www/html/artisan queue:work --tries=3 --timeout=90 --sleep=3 --backoff=3
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/queue.log
EOF

# Entrypoint script
COPY <<'EOF' /usr/local/bin/docker-entrypoint.sh
#!/bin/bash
set -e

FLAG_FILE="/var/www/html/storage/.migrations_done"

if [ ! -f "$FLAG_FILE" ]; then
    echo "First run detected - Running migrations..."
    php artisan storage:link
    php artisan migrate --force --isolated
    echo "Migrations completed!"
    touch "$FLAG_FILE"
else
    echo "Migrations already run, skipping..."
fi

php artisan optimize:clear
php artisan config:cache
php artisan route:cache
php artisan view:cache

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
EOF

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
