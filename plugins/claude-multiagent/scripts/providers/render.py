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


def load_config():
    """Load config from .deploy-watch.json in current directory."""
    config_path = os.path.join(os.getcwd(), ".deploy-watch.json")
    if not os.path.isfile(config_path):
        print("Error: .deploy-watch.json not found in current directory", file=sys.stderr)
        sys.exit(1)

    with open(config_path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            print(f"Error: invalid JSON in .deploy-watch.json: {e}", file=sys.stderr)
            sys.exit(1)

    render_cfg = data.get("config", {}).get("render", {})
    service_id = render_cfg.get("serviceId")
    if not service_id:
        print("Error: config.render.serviceId is required in .deploy-watch.json", file=sys.stderr)
        sys.exit(1)

    api_key_env = render_cfg.get("apiKeyEnv", "RENDER_API_KEY")
    api_key = os.environ.get(api_key_env)
    if not api_key:
        print(f"Error: environment variable {api_key_env} is not set", file=sys.stderr)
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
    """Convert an ISO 8601 timestamp to unix epoch integer.

    Handles formats like 2024-01-15T12:30:00Z and 2024-01-15T12:30:00.000Z.
    Returns None if the input is None or empty.
    """
    if not iso_str:
        return None
    # Strip trailing Z and any fractional seconds for parsing
    s = iso_str.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
        return int(dt.timestamp())
    except (ValueError, TypeError):
        return None


def cmd_name():
    print("Render")


def cmd_config():
    config = {
        "fields": [
            {
                "key": "serviceId",
                "label": "Service ID",
                "description": "Render service ID (e.g. srv-xxx)",
                "required": True,
            },
            {
                "key": "apiKeyEnv",
                "label": "API key env var",
                "description": "Environment variable containing your Render API key",
                "default": "RENDER_API_KEY",
                "required": False,
            },
        ]
    }
    print(json.dumps(config))


def cmd_list():
    service_id, api_key = load_config()

    # Get service details for the URL
    service = api_get(f"/services/{service_id}", api_key)
    service_url = None
    if isinstance(service, dict):
        service_details = service.get("service", service)
        service_url = service_details.get("serviceDetails", {}).get("url") or service_details.get("url")

    # Get recent deploys
    deploys_raw = api_get(f"/services/{service_id}/deploys?limit=15", api_key)

    # The API may return a list of objects or a list of {deploy: ...} wrappers
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
        updated_at = iso_to_epoch(deploy.get("updatedAt"))
        finished_at = iso_to_epoch(deploy.get("finishedAt"))

        # Determine build vs deploy timing
        # Render doesn't separate build/deploy timestamps explicitly,
        # so we approximate: build_started = createdAt, and use
        # finishedAt for both build_finished and deploy_finished when live.
        record = {}
        record["commit"] = commit_obj.get("id", "")[:7] if commit_obj.get("id") else ""
        record["message"] = commit_obj.get("message", "")
        record["author"] = commit_obj.get("createdAt", "")  # Render doesn't expose author email directly

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
            # Could be build or deploy failure
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

        # Timestamps
        if created_at is not None:
            record["build_started"] = str(created_at)
        if mapped_status in ("live", "failed", "cancelled") and finished_at is not None:
            record["build_finished"] = str(finished_at)
            if mapped_status == "live":
                record["deploy_started"] = str(finished_at)
                record["deploy_finished"] = str(finished_at)
        elif mapped_status == "deploying" and updated_at is not None:
            record["build_finished"] = str(updated_at)
            record["deploy_started"] = str(updated_at)

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
