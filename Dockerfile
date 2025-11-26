# This python image is tested to work fine with Playwright
FROM python:3.11.14-slim-bookworm AS builder

WORKDIR /build

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Lazre venv and dependencies
COPY lazre/requirements.txt /build/lazre/requirements.txt
RUN python -m venv /build/lazre/venv && \
    /build/lazre/venv/bin/pip install --upgrade pip && \
    /build/lazre/venv/bin/pip install --no-cache-dir -r /build/lazre/requirements.txt

# Install NLTK data and Playwright for lazre
COPY lazre/install_nltk.py /build/
RUN /build/lazre/venv/bin/python /build/install_nltk.py
RUN /build/lazre/venv/bin/playwright install && /build/lazre/venv/bin/playwright install-deps

# Bot915 venv and dependencies
COPY bot915/requirements.txt /build/bot915/requirements.txt
RUN python -m venv /build/bot915/venv && \
    /build/bot915/venv/bin/pip install --upgrade pip && \
    /build/bot915/venv/bin/pip install --no-cache-dir -r /build/bot915/requirements.txt

# Taggregator venv and dependencies
COPY taggregator/requirements.txt /build/taggregator/requirements.txt
RUN python -m venv /build/taggregator/venv && \
    /build/taggregator/venv/bin/pip install --upgrade pip && \
    /build/taggregator/venv/bin/pip install --no-cache-dir -r /build/taggregator/requirements.txt

# This python image is tested to work fine with Playwright
FROM python:3.11.14-slim-bookworm

# Create non-root user
RUN useradd -m -u 1000 appuser

# Create data and temp directories for all applications
RUN mkdir -p /var/lib/lazre && \
    mkdir -p /tmp && \
    chown -R appuser:appuser /var/lib/lazre && \
    chown -R appuser:appuser /tmp && \
    chmod -R 755 /var/lib/lazre && \
    chmod -R 755 /tmp

# Copy application code
COPY lazre /app/lazre
COPY bot915 /app/bot915
COPY taggregator /app/taggregator
COPY scheduler.py /app/taggregator/scheduler.py

# Copy venvs from builder into app folders
COPY --from=builder /build/lazre/venv /app/lazre/venv
COPY --from=builder /build/bot915/venv /app/bot915/venv
COPY --from=builder /build/taggregator/venv /app/taggregator/venv

# Copy start script
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Set working directory
WORKDIR /app

# Switch to non-root user
USER appuser

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV VECTORSTORE_DATA_DIRECTORY=/var/lib/lazre/chroma
ENV TAGGREGATOR_DATA_DIRECTORY=/var/lib/lazre/taggregator
ENV BOT915_EULA_USERS_FILE_PATH=/var/lib/lazre/users_settings/eula_users.json
ENV MESSAGES_LOG_WORKDIR=/var/lib/lazre/taggregator
ENV TMPDIR=/tmp/lazre
ENV BOT915_CONFIG_FILE_PATH=/var/lib/lazre/config/config_bot915.json
ENV TAGGREGATOR_CONFIG_FILE_PATH=/var/lib/lazre/config/config_taggregator.json
ENV LAZRE_CONFIG_FILE_PATH=/var/lib/lazre/config/config_lazre.json

# Set environment variables for venvs in app folders, they will be used in the start.sh script
ENV VENV_LAZRE_PATH=/app/lazre/venv
ENV VENV_BOT915_PATH=/app/bot915/venv
ENV VENV_TAGGREGATOR_PATH=/app/taggregator/venv

# Expose ports if needed
# EXPOSE 8083

# Use the startup script as the entry point
CMD ["/app/start.sh"]
