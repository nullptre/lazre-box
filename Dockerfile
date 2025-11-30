# This base image is tested to work fine with Playwright:
FROM python:3.11.14-slim-bookworm

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1000 appuser

# Create data and temp directories for all applications
# NOTE: leave /tmp with default permissions (1777, root-owned) so system tools like apt can use it.
# Use a dedicated subdirectory /tmp/lazre for our app's temporary files.
RUN mkdir -p /var/lib/lazre && \
    mkdir -p /tmp/lazre && \
    chown -R appuser:appuser /var/lib/lazre /tmp/lazre && \
    chmod -R 755 /var/lib/lazre /tmp/lazre

# Copy application code
COPY lazre /app/lazre
COPY bot915 /app/bot915
COPY taggregator /app/taggregator
COPY scheduler.py /app/taggregator/scheduler.py

# Lazre venv and dependencies
RUN python -m venv /app/lazre/venv && \
    /app/lazre/venv/bin/pip install --upgrade pip && \
    /app/lazre/venv/bin/pip install --no-cache-dir -r /app/lazre/requirements.txt

# Bot915 venv and dependencies
RUN python -m venv /app/bot915/venv && \
    /app/bot915/venv/bin/pip install --upgrade pip && \
    /app/bot915/venv/bin/pip install --no-cache-dir -r /app/bot915/requirements.txt

# Taggregator venv and dependencies
RUN python -m venv /app/taggregator/venv && \
    /app/taggregator/venv/bin/pip install --upgrade pip && \
    /app/taggregator/venv/bin/pip install --no-cache-dir -r /app/taggregator/requirements.txt

# Lazre: Install Playwright system dependencies as root (this may use apt-get under the hood)
RUN /app/lazre/venv/bin/playwright install-deps

# Copy start scripts
COPY start.sh /app/start.sh
COPY start_indexing.sh /app/start_indexing.sh
RUN chmod +x /app/start.sh /app/start_indexing.sh

# Switch to non-root user
USER appuser

# Lazre: Install Playwright supported browsers for appuser
RUN /app/lazre/venv/bin/playwright install
# Lazre: Install NLTK data for appuser
RUN /app/lazre/venv/bin/python /app/lazre/install_nltk.py

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
