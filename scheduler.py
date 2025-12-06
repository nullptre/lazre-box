from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import List

import schedule


@dataclass
class LazreChatConfig:
    chat_day_start: str
    enable_shcheduled_indexing: bool = True
    # Optional: chat identifier used by Lazre; when available, we forward it
    # to the Lazre API when triggering indexing.
    chat_id: str | None = None


@dataclass
class LazreConfig:
    chats: List[LazreChatConfig]


def get_lazre_config_path() -> str:
    """
    Resolve the Lazre config path.

    Uses the docker-provided LAZRE_CONFIG_FILE_PATH when available and
    falls back to the local project path for non-docker execution.
    """
    env_path = os.getenv("LAZRE_CONFIG_FILE_PATH")
    if env_path:
        return env_path

    return os.path.join("config", "config_lazre.json")


def load_lazre_config(config_path: str) -> LazreConfig:
    """
    Load Lazre configuration from JSON.

    The JSON format is expected to be a list of chat configuration objects.
    """
    with open(config_path, "r", encoding="utf-8") as config_file:
        raw_data = json.load(config_file)

    if not isinstance(raw_data, list):
        raise ValueError("Lazre config must be a list of chat configurations.")

    chats: List[LazreChatConfig] = []
    for item in raw_data:
        if not isinstance(item, dict):
            raise ValueError("Each Lazre chat configuration must be an object.")

        chat_config = LazreChatConfig(
            chat_day_start=str(item.get("chat_day_start", "")),
            enable_shcheduled_indexing=bool(
                item.get("enable_shcheduled_indexing", True)
            ),
            chat_id=str(item.get("chat_id")) if item.get("chat_id") is not None else None,
        )
        chats.append(chat_config)

    return LazreConfig(chats=chats)


def get_scheduler_chat_config(config: LazreConfig) -> LazreChatConfig:
    """
    Select the chat configuration to drive the scheduler.

    Currently, this uses the first chat entry.
    """
    if not config.chats:
        raise ValueError("Lazre config does not contain any chat entries.")

    # TODO: Support selecting a specific chat configuration instead of always
    #       using the first one.
    return config.chats[0]


def parse_chat_day_start(chat_day_start: str) -> str:
    """
    Validate and normalize the chat_day_start time string.

    Returns the time string in HH:MM:SS format, which is accepted by the
    schedule library.
    """
    if not chat_day_start:
        raise ValueError("chat_day_start must not be empty.")

    # Accept strings with seconds; if format needs to evolve, extend this.
    try:
        parsed_time = datetime.strptime(chat_day_start, "%H:%M:%S")
    except ValueError as exc:
        # TODO: Support additional time formats in config_lazre.json if needed.
        raise ValueError(
            f"Invalid chat_day_start format: {chat_day_start!r}. "
            "Expected format is HH:MM:SS."
        ) from exc

    return parsed_time.strftime("%H:%M:%S")


def get_lazre_base_url() -> str:
    """
    Resolve the Lazre server base URL.

    In docker, Lazre runs in the same container, so localhost is correct.
    """
    # TODO: Consider moving the Lazre base URL to configuration if the server
    #       address or port ever needs to be customized.
    return os.getenv("LAZRE_SERVER_URL", "http://127.0.0.1:8083")


def call_index_topics_endpoint() -> None:
    """
    Call the Lazre /api/index-topics REST endpoint.
    """
    base_url = get_lazre_base_url().rstrip("/")
    url = f"{base_url}/api/index-topics"

    # The Lazre /api/index-topics endpoint expects a JSON body with at least
    # a chat_id field. The actual indexing routine currently runs for all
    # chats, but chat_id is still required by the API schema.
    #
    # We resolve the Lazre config again here to get the scheduler chat entry
    # and reuse its chat_id when available. If it is missing for any reason,
    # we fall back to an empty string, which is still accepted by the server.
    try:
        lazre_config_path = get_lazre_config_path()
        lazre_config = load_lazre_config(lazre_config_path)
        scheduler_chat_config = get_scheduler_chat_config(lazre_config)
        chat_id = (scheduler_chat_config.chat_id or "").strip()
    except Exception:
        # If anything goes wrong while resolving config, still attempt to call
        # the endpoint with a dummy chat_id so that indexing can proceed.
        chat_id = ""

    payload = {"chat_id": chat_id}
    data = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(
        url=url,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json"},
    )

    try:
        print(
            "SCHEDULED JOB: Calling index topics endpoint: "
            f"{url} with payload: {payload}"
        )
        with urllib.request.urlopen(request) as response:
            status_code = response.getcode()
            print(f"Index topics endpoint responded with status code {status_code}.")
    except urllib.error.HTTPError as http_error:
        print(
            "Failed to call index topics endpoint: "
            f"HTTP {http_error.code} - {http_error.reason}"
        )
    except urllib.error.URLError as url_error:
        print(f"Failed to call index topics endpoint: {url_error.reason}")


def run_taggregator() -> None:
    """
    Run taggregator main process once.
    """
    # Get current environment and ensure it's passed to the child process.
    # Use the same Python interpreter that is running this scheduler
    # (i.e., the taggregator venv Python inside Docker).
    env = os.environ.copy()
    print("SCHEDULED JOB: Running taggregator.")
    subprocess.run([sys.executable, "main.py"], env=env)


def setup_schedules() -> None:
    """
    Configure all periodic tasks for the scheduler.
    """
    print("Configuring taggregator scheduler tasks.")

    # Schedule taggregator to run every 10 minutes.
    schedule.every(30).minutes.do(run_taggregator)

    # Load Lazre configuration and schedule the daily indexing job.
    lazre_config_path = get_lazre_config_path()
    lazre_config = load_lazre_config(lazre_config_path)
    scheduler_chat_config = get_scheduler_chat_config(lazre_config)
    index_time = parse_chat_day_start(scheduler_chat_config.chat_day_start)

    if not scheduler_chat_config.enable_shcheduled_indexing:
        print(
            "Daily index-topics job is disabled by "
            "config (enable_shcheduled_indexing = false)."
        )
    else:
        schedule.every().day.at(index_time).do(call_index_topics_endpoint)
        print(
            "Scheduled daily index-topics job at "
            f"{index_time} based on Lazre config."
        )


def run_scheduler_loop() -> None:
    """
    Run the scheduler loop indefinitely.
    """
    print("Starting taggregator scheduler loop. Current UTC time:", datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"))
    while True:
        schedule.run_pending()
        time.sleep(60)


if __name__ == "__main__":
    setup_schedules()
    run_scheduler_loop()
