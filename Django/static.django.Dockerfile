# 1. Base Image
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# 2. Install System Dependencies & Apache
# libapache2-mod-wsgi-py3: Connects Apache to Python 3
# apache2: The web server
RUN apt-get update && apt-get install -y \
    apache2 \
    libapache2-mod-wsgi-py3 \
    libpq-dev \
    gcc \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 3. Install Python Dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 4. Copy Project Code
COPY . .

# ==============================================================================
# 5. CONFIGURE APACHE (Write config file in-place)
# ==============================================================================
# We overwrite the default Apache site configuration.
# REPLACE 'myproject' with your actual project folder name!
RUN echo '<VirtualHost *:80>' > /etc/apache2/sites-available/000-default.conf && \
    echo '    # 1. Server Logs' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    ErrorLog ${APACHE_LOG_DIR}/error.log' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    CustomLog ${APACHE_LOG_DIR}/access.log combined' >> /etc/apache2/sites-available/000-default.conf && \
    echo '' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    # 2. Serve Static Files Directly' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    Alias /static /app/staticfiles' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    <Directory /app/staticfiles>' >> /etc/apache2/sites-available/000-default.conf && \
    echo '        Require all granted' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    </Directory>' >> /etc/apache2/sites-available/000-default.conf && \
    echo '' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    # 3. Serve Media Files Directly' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    Alias /media /app/media' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    <Directory /app/media>' >> /etc/apache2/sites-available/000-default.conf && \
    echo '        Require all granted' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    </Directory>' >> /etc/apache2/sites-available/000-default.conf && \
    echo '' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    # 4. Serve Django Application (WSGI)' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    # python-home points to global python libraries' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    WSGIDaemonProcess myproject python-home=/usr/local python-path=/app' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    WSGIProcessGroup myproject' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    WSGIScriptAlias / /app/myproject/wsgi.py' >> /etc/apache2/sites-available/000-default.conf && \
    echo '' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    <Directory /app/myproject>' >> /etc/apache2/sites-available/000-default.conf && \
    echo '        <Files wsgi.py>' >> /etc/apache2/sites-available/000-default.conf && \
    echo '            Require all granted' >> /etc/apache2/sites-available/000-default.conf && \
    echo '        </Files>' >> /etc/apache2/sites-available/000-default.conf && \
    echo '    </Directory>' >> /etc/apache2/sites-available/000-default.conf && \
    echo '</VirtualHost>' >> /etc/apache2/sites-available/000-default.conf

# ==============================================================================
# 6. CREATE ENTRYPOINT SCRIPT (Write script in-place)
# ==============================================================================
RUN echo '#!/bin/bash' > /app/entrypoint.sh && \
    echo 'set -e' >> /app/entrypoint.sh && \
    echo 'echo "--- Creating Media Directory ---"' >> /app/entrypoint.sh && \
    echo 'mkdir -p /app/media' >> /app/entrypoint.sh && \
    echo 'echo "--- Running Migrations ---"' >> /app/entrypoint.sh && \
    echo 'python manage.py migrate' >> /app/entrypoint.sh && \
    echo 'echo "--- Collecting Static Files ---"' >> /app/entrypoint.sh && \
    echo 'python manage.py collectstatic --noinput' >> /app/entrypoint.sh && \
    echo 'echo "--- Setting Permissions ---"' >> /app/entrypoint.sh && \
    echo '# Give Apache (www-data) ownership of media and static files so it can read/write' >> /app/entrypoint.sh && \
    echo 'chown -R www-data:www-data /app/media /app/staticfiles' >> /app/entrypoint.sh && \
    echo 'echo "--- Starting Apache ---"' >> /app/entrypoint.sh && \
    echo '# Run Apache in the foreground' >> /app/entrypoint.sh && \
    echo 'exec /usr/sbin/apache2ctl -D FOREGROUND' >> /app/entrypoint.sh && \
    chmod +x /app/entrypoint.sh

# 7. Expose Port 80
EXPOSE 80

# 8. Start Container
ENTRYPOINT ["/app/entrypoint.sh"]