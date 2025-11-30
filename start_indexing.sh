#!/bin/bash

set -euo pipefail

# Create log directory if it doesn't exist
mkdir -p /var/lib/lazre/logs/lazre

echo "Starting lazre indexing..."
cd /app/lazre

# Run indexing and append output to a dedicated indexing log,
# while still sending it to stdout/stderr for CloudWatch Logs.
"${VENV_LAZRE_PATH}"/bin/python util_index_topics.py 2>&1 | tee -a /var/lib/lazre/logs/lazre/lazre_indexing.log


