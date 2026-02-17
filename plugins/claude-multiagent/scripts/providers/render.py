#!/usr/bin/env python3
"""Render.com deploy provider for deploy-watch."""

import json
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime

RENDER_API_BASE = "https://api.render.com/v1"
TIMEOUT = 10


def get_config_from_env():
    """Read provider config from DEPLOY_WATCH_* environment variables."""
    service_id = os.environ.get("DEPLOY_WATCH_SERVICEID", "")
    if not service_id:
        print("Error: DEPLOY_WATCH_SERVICEID is not set", file=sys.stderr)
        sys.exit(1)

    api_key_env = os.environ.get("DEPLOY_WATCH_APIKEYENV", "RENDER_DOT_COM_TOK")
    api_key = os.environ.get(api_key_env, "")
    if not api_key:
        print(
            f"Error: environment variable {api_key_env} is not set. "
            f"Set it to your Render API key, or specify a different env var "
            f"name via apiKeyEnv in .deploy-watch.json.",
            file=sys.stderr,
        )
        sys.exit(1)

    return service_id, api_key


def api_get(path, api_key):
    """Make an authenticated GET request to the Render API."""
    url = f"{RENDER_API_BASE}{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        print(f"Error: Render API returned {e.code}: {body}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Error: could not reach Render API: {e.reason}", file=sys.stderr)
        sys.exit(1)


STATUS_MAP = {
    "created": "pending",
    "build_in_progress": "building",
    "update_in_progress": "deploying",
    "live": "live",
    "build_failed": "failed",
    "update_failed": "failed",
    "canceled": "cancelled",
    "deactivated": "cancelled",
}


def iso_to_epoch(iso_str):
    """Convert an ISO 8601 timestamp to unix epoch string.

    Handles formats like 2024-01-15T12:30:00Z and 2024-01-15T12:30:00.000Z.
    Returns empty string if the input is None or empty.
    """
    if not iso_str:
        return ""
    s = iso_str.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
        return str(int(dt.timestamp()))
    except (ValueError, TypeError):
        return ""


def cmd_name():
    print("Render")


def cmd_config():
    config = {
        "fields": [
            {
                "key": "serviceId",
                "label": "Service ID (srv-xxx)",
                "required": True,
            },
            {
                "key": "apiKeyEnv",
                "label": "API Key env var",
                "required": False,
                "default": "RENDER_DOT_COM_TOK",
            },
        ]
    }
    print(json.dumps(config))


def cmd_list():
    service_id, api_key = get_config_from_env()

    # Get service details for the URL
    service_url = ""
    try:
        service = api_get(f"/services/{service_id}", api_key)
        if isinstance(service, dict):
            service_url = (
                service.get("serviceDetails", {}).get("url", "")
                or service.get("url", "")
            )
    except SystemExit:
        pass  # Non-fatal; continue without service URL

    # Get recent deploys
    deploys_raw = api_get(f"/services/{service_id}/deploys?limit=10", api_key)

    # The API returns a list of {deploy: ...} wrapper objects
    deploys = []
    if isinstance(deploys_raw, list):
        for item in deploys_raw:
            if isinstance(item, dict) and "deploy" in item:
                deploys.append(item["deploy"])
            else:
                deploys.append(item)

    for deploy in deploys:
        status_raw = deploy.get("status", "")
        mapped_status = STATUS_MAP.get(status_raw, status_raw)

        commit_obj = deploy.get("commit", {}) or {}

        # Build timestamps
        created_at = iso_to_epoch(deploy.get("createdAt"))
        finished_at = iso_to_epoch(deploy.get("finishedAt"))

        # Extract commit info
        commit_id = commit_obj.get("id", "")
        commit_msg = (commit_obj.get("message", "") or "").split("\n")[0]

        record = {
            "commit": commit_id[:7] if commit_id else "",
            "message": commit_msg,
            "author": deploy.get("creator", {}).get("name", "")
                      or deploy.get("creator", {}).get("email", ""),
        }

        # Map build/deploy status
        if mapped_status in ("pending", "building"):
            record["build_status"] = mapped_status
            record["deploy_status"] = "pending"
        elif mapped_status == "deploying":
            record["build_status"] = "success"
            record["deploy_status"] = "deploying"
        elif mapped_status == "live":
            record["build_status"] = "success"
            record["deploy_status"] = "live"
        elif mapped_status == "failed":
            if status_raw == "build_failed":
                record["build_status"] = "failed"
                record["deploy_status"] = "pending"
            else:
                record["build_status"] = "success"
                record["deploy_status"] = "failed"
        elif mapped_status == "cancelled":
            record["build_status"] = "cancelled"
            record["deploy_status"] = "cancelled"
        else:
            record["build_status"] = mapped_status
            record["deploy_status"] = mapped_status

        # Timestamps — build_started = createdAt, deploy_finished = finishedAt
        record["build_started"] = created_at
        if mapped_status in ("live",) and finished_at:
            record["deploy_finished"] = finished_at
        else:
            record["deploy_finished"] = ""

        if service_url:
            record["service_url"] = service_url

        print(json.dumps(record))


def main():
    if len(sys.argv) < 2:
        print("Usage: render.py <name|config|list>", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "name":
        cmd_name()
    elif cmd == "config":
        cmd_config()
    elif cmd == "list":
        cmd_list()
    else:
        print(f"Error: unknown command '{cmd}'", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
