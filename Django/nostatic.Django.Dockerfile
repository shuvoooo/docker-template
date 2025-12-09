# 1. Setup Base Image
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# 2. Install System Deps
RUN apt-get update && apt-get install -y \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# 3. Install Python Deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt gunicorn

# 4. Copy Project Code
COPY . .

# 5. CREATE ENTRYPOINT SCRIPT IN-PLACE
# This block writes the script lines to a file inside the image
RUN echo '#!/bin/sh' > /app/entrypoint.sh && \
    echo 'set -e' >> /app/entrypoint.sh && \
    echo 'echo "--- Running Migrations ---"' >> /app/entrypoint.sh && \
    echo 'python manage.py migrate' >> /app/entrypoint.sh && \
    echo 'echo "--- Collecting Static Files ---"' >> /app/entrypoint.sh && \
    echo 'python manage.py collectstatic --noinput' >> /app/entrypoint.sh && \
    echo 'echo "--- Starting Application ---"' >> /app/entrypoint.sh && \
    echo 'exec "$@"' >> /app/entrypoint.sh && \
    chmod +x /app/entrypoint.sh

# 6. Set Entrypoint and Default Command
ENTRYPOINT ["/app/entrypoint.sh"]

# Replace 'config.wsgi:application' with your actual project name
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "config.wsgi:application"]