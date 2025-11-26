#!/bin/bash

# Create log directories if they don't exist
mkdir -p /var/lib/lazre/logs/bot915
mkdir -p /var/lib/lazre/logs/taggregator

# Run taggregator once in foreground for initial authentication and messages download
echo "Running taggregator for initial authentication..."
echo "During the authentication process, check your Telegram app for the verification code."
echo "**IMPORTANT: After successful authentication it will download all the messages from the past N days, so it might take a while.**"
cd /app/taggregator
$VENV_TAGGREGATOR_PATH/bin/python main.py --interactive-init-config 2>&1 | tee -a /var/lib/lazre/logs/taggregator/taggregator.log

# Check if the app run successfully and if not then abort
if [ $? -ne 0 ]; then
    echo "Taggregator failed to start. Aborting setup."
    exit 1
fi
echo "Taggregator authentication was successful. Now you can relax."

# Start bot915 in the background with logging
echo "Starting bot915..."
cd /app/bot915
$VENV_BOT915_PATH/bin/python main.py >> /var/lib/lazre/logs/bot915/bot.log 2>&1 &

# Start taggregator scheduler in the background
echo "Starting taggregator scheduler..."
cd /app/taggregator
$VENV_TAGGREGATOR_PATH/bin/python scheduler.py >> /var/lib/lazre/logs/taggregator/taggregator.log 2>&1 &

# Start lazre in the foreground
echo "Starting lazre server..."
cd /app/lazre
$VENV_LAZRE_PATH/bin/python server.py 2>&1 | tee -a /var/lib/lazre/logs/lazre/lazre.log
