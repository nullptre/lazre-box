import schedule
import time
import subprocess
import os

def run_taggregator():
    # Get current environment and ensure it's passed to the child process
    env = os.environ.copy()
    subprocess.run(['python', 'main.py'], env=env)

print("Starting taggregator scheduler.")

# Schedule to run every 30 minutes
schedule.every(10).minutes.do(run_taggregator)

# Run in background
while True:
    schedule.run_pending()
    time.sleep(60) 