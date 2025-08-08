# Use Python 3.11 slim as base image
FROM python:3.11-slim AS builder

# Set working directory
WORKDIR /build

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create and activate virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install Python dependencies for all applications
COPY lazre/requirements.txt /build/lazre-requirements.txt
COPY bot915/requirements.txt /build/bot915-requirements.txt
COPY taggregator/requirements.txt /build/taggregator-requirements.txt

RUN pip install --no-cache-dir -r /build/lazre-requirements.txt && \
    pip install --no-cache-dir -r /build/bot915-requirements.txt && \
    pip install --no-cache-dir -r /build/taggregator-requirements.txt && \
    pip install --no-cache-dir schedule

# Install NLTK data and Playwright for lazre
COPY lazre/install_nltk.py /build/
RUN python /build/install_nltk.py
RUN playwright install && playwright install-deps

# Final stage
FROM python:3.11-slim

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

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

# Copy and setup startup script
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

# Expose ports
# EXPOSE 8083

# Use the startup script as the entry point
CMD ["/app/start.sh"]
