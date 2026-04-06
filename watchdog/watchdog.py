#!/usr/bin/env python3
"""
watchdog.py — runs on the Minecraft EC2 instance as a systemd service.

Responsibilities:
  1. On startup: fetch the instance's public IP and update the Route53 A record.
  2. Poll the Minecraft server every 60s for player count.
  3. After INACTIVITY_MINUTES consecutive minutes of zero players, stop the instance.
  4. Broadcast in-game warnings before shutdown via RCON.
  5. Respond to in-game commands: /shutdown (immediate) and /extend (+1 hour).
  6. Handle SIGTERM cleanly (e.g. from systemd on OS shutdown).
"""

import json
import logging
import os
import re
import signal
import sys
import time
import urllib.request
from typing import Optional

import boto3
from botocore.exceptions import ClientError
from mcstatus import JavaServer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger(__name__)


def _log(event: str, **kwargs) -> None:
    logger.info(json.dumps({"event": event, **kwargs}))


# ── Config from environment (set by user_data.sh) ──────────────────────────

def _require_env(key: str) -> str:
    value = os.environ.get(key)
    if not value:
        raise RuntimeError(f"Required environment variable {key!r} is not set")
    return value


INSTANCE_ID = _require_env("INSTANCE_ID")
HOSTED_ZONE_ID = _require_env("HOSTED_ZONE_ID")
DOMAIN_NAME = _require_env("DOMAIN_NAME")
AWS_REGION = _require_env("AWS_REGION")
INACTIVITY_MINUTES = int(os.environ.get("INACTIVITY_MINUTES", "20"))
RCON_PASSWORD = os.environ.get("RCON_PASSWORD", "")
POLL_INTERVAL_SECONDS = 60
MC_HOST = "localhost"
MC_PORT = 25565
RCON_PORT = 25575
MC_LOG_PATH = "/opt/minecraft/logs/latest.log"


# ── IMDSv2 helpers ──────────────────────────────────────────────────────────

def _imds_token() -> str:
    """Fetch a short-lived IMDSv2 token."""
    req = urllib.request.Request(
        "http://169.254.169.254/latest/api/token",
        method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return resp.read().decode()


def get_public_ip() -> str:
    token = _imds_token()
    req = urllib.request.Request(
        "http://169.254.169.254/latest/meta-data/public-ipv4",
        headers={"X-aws-ec2-metadata-token": token},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        ip = resp.read().decode().strip()
    _log("got_public_ip", ip=ip)
    return ip


# ── Route53 ─────────────────────────────────────────────────────────────────

def update_dns(ip: str) -> None:
    r53 = boto3.client("route53")
    change = {
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "Name": DOMAIN_NAME,
            "Type": "A",
            "TTL": 30,
            "ResourceRecords": [{"Value": ip}],
        },
    }
    try:
        resp = r53.change_resource_record_sets(
            HostedZoneId=HOSTED_ZONE_ID,
            ChangeBatch={"Changes": [change]},
        )
        _log("dns_updated", ip=ip, change_id=resp["ChangeInfo"]["Id"])
    except ClientError as e:
        _log("dns_update_failed", ip=ip, error=str(e))
        raise


# ── Player count ─────────────────────────────────────────────────────────────

def get_player_count() -> Optional[int]:
    """Return current player count, or None if the server is unreachable."""
    try:
        server = JavaServer(MC_HOST, MC_PORT, timeout=10)
        status = server.status()
        return status.players.online
    except Exception as e:
        _log("query_failed", error=str(e))
        return None


# ── RCON ─────────────────────────────────────────────────────────────────────

def rcon_say(message: str) -> None:
    """Broadcast a message to all in-game players via RCON."""
    if not RCON_PASSWORD:
        return
    try:
        server = JavaServer(MC_HOST, MC_PORT)
        with server.rcon_connection(password=RCON_PASSWORD, port=RCON_PORT) as rcon:
            rcon.command(f"say {message}")
        _log("rcon_say", message=message)
    except Exception as e:
        _log("rcon_say_failed", message=message, error=str(e))


# ── Log tailing ──────────────────────────────────────────────────────────────

def _log_end_position() -> int:
    """Return the current end-of-file position so we only read new lines."""
    try:
        with open(MC_LOG_PATH) as f:
            f.seek(0, 2)
            return f.tell()
    except (FileNotFoundError, OSError):
        return 0


def _read_new_log_lines(position: int) -> tuple[list[str], int]:
    try:
        with open(MC_LOG_PATH) as f:
            f.seek(position)
            lines = f.readlines()
            return lines, f.tell()
    except (FileNotFoundError, OSError):
        return [], position


def check_commands(lines: list[str]) -> tuple[bool, bool]:
    """Scan new log lines for player commands. Returns (shutdown, extend)."""
    shutdown = any(re.search(r"issued server command: /shutdown", line) for line in lines)
    extend = any(re.search(r"issued server command: /extend", line) for line in lines)
    return shutdown, extend


# ── Self-stop ────────────────────────────────────────────────────────────────

def stop_instance() -> None:
    ec2 = boto3.client("ec2", region_name=AWS_REGION)
    _log("stopping_instance", instance_id=INSTANCE_ID)
    try:
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
    except ClientError as e:
        _log("stop_failed", instance_id=INSTANCE_ID, error=str(e))
        raise
    # Systemd will kill the process once the instance actually stops
    sys.exit(0)


# ── Signal handling ──────────────────────────────────────────────────────────

_shutdown_requested = False


def _handle_sigterm(signum, frame):
    global _shutdown_requested
    _log("sigterm_received")
    _shutdown_requested = True


signal.signal(signal.SIGTERM, _handle_sigterm)


# ── Main loop ────────────────────────────────────────────────────────────────

def wait_for_server(max_wait_seconds: int = 300) -> None:
    """Block until the Minecraft server is accepting connections."""
    deadline = time.monotonic() + max_wait_seconds
    while time.monotonic() < deadline:
        if _shutdown_requested:
            sys.exit(0)
        count = get_player_count()
        if count is not None:
            _log("server_ready")
            return
        _log("waiting_for_server")
        time.sleep(10)
    raise RuntimeError("Minecraft server did not start within the timeout window")


def main() -> None:
    _log("watchdog_starting", instance_id=INSTANCE_ID, domain=DOMAIN_NAME,
         inactivity_minutes=INACTIVITY_MINUTES)

    # 1. Update DNS to point at this instance's IP
    ip = get_public_ip()
    update_dns(ip)

    # 2. Wait for the Minecraft process to be ready
    wait_for_server()

    # 3. Initialise log position — only read lines written after this point
    log_position = _log_end_position()

    # 4. Poll loop
    empty_ticks = 0
    required_empty_ticks = INACTIVITY_MINUTES  # one tick per minute
    warned_5 = False
    warned_1 = False

    while not _shutdown_requested:
        time.sleep(POLL_INTERVAL_SECONDS)

        if _shutdown_requested:
            break

        # Check log for player commands
        new_lines, log_position = _read_new_log_lines(log_position)
        shutdown_cmd, extend_cmd = check_commands(new_lines)

        if shutdown_cmd:
            _log("shutdown_command_received")
            rcon_say("Server hibernating in 30 seconds.")
            time.sleep(30)
            stop_instance()

        if extend_cmd:
            _log("extend_command_received")
            empty_ticks = -60  # 60 more minutes before threshold is reached
            warned_5 = False
            warned_1 = False
            rcon_say("Shutdown cancelled. Server will stay up for 1 more hour.")
            continue

        count = get_player_count()

        if count is None:
            _log("server_unreachable", empty_ticks=empty_ticks)
            empty_ticks += 1
        elif count > 0:
            _log("players_online", count=count)
            empty_ticks = 0
            warned_5 = False
            warned_1 = False
        else:
            empty_ticks += 1
            _log("server_empty", empty_ticks=empty_ticks, required=required_empty_ticks)

        ticks_remaining = required_empty_ticks - empty_ticks

        if ticks_remaining == 5 and not warned_5:
            rcon_say("Server hibernating in 5 minutes due to inactivity. Type /extend to delay.")
            warned_5 = True

        if ticks_remaining == 1 and not warned_1:
            rcon_say("Server hibernating in 1 minute due to inactivity. Type /extend to delay.")
            warned_1 = True

        if empty_ticks >= required_empty_ticks:
            _log("inactivity_threshold_reached", empty_ticks=empty_ticks)
            rcon_say("Server is now hibernating. See you next time!")
            time.sleep(2)
            stop_instance()

    _log("watchdog_exiting")


if __name__ == "__main__":
    main()
