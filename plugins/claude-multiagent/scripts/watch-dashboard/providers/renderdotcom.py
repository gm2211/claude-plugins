#!/usr/bin/env python3
"""Render.com deploy provider for deploy-watch.

Auto-discovers all web services in the workspace and fetches recent
deploys for each, returning them as interleaved JSON-line records
sorted by time (most recent first).
"""

import json
import logging
import os
import ssl
import sys
import traceback
import urllib.request
import urllib.error
from datetime import datetime

# ---------------------------------------------------------------------------
# Debug logging — writes to /tmp/deploy-watch-render.log
# ---------------------------------------------------------------------------

_log = logging.getLogger("deploy-watch-render")
_log.setLevel(logging.DEBUG)
_log.propagate = False
if not _log.handlers:
    import tempfile
    _log_path = os.path.join(tempfile.gettempdir(), "deploy-watch-render.log")
    try:
        _fh = logging.FileHandler(_log_path)
        _fh.setFormatter(logging.Formatter(
            "%(asctime)s %(levelname)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
        ))
        _log.addHandler(_fh)
    except (PermissionError, OSError):
        _log.addHandler(logging.NullHandler())

try:
    import certifi
    SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())
    _log.debug("SSL: using certifi (%s)", certifi.where())
except (ImportError, AttributeError):
    SSL_CONTEXT = None
    _log.debug("SSL: certifi not available, SSL_CONTEXT=None")

RENDER_API_BASE = "https://api.render.com/v1"
TIMEOUT = 10
DEPLOYS_PER_SERVICE = 5
MAX_TOTAL_RECORDS = 20


def get_config_from_env():
    """Read provider config from DEPLOY_WATCH_* environment variables."""
    owner_id = os.environ.get("DEPLOY_WATCH_OWNERID", "")
    _log.debug("DEPLOY_WATCH_OWNERID %s", owner_id or "NOT SET (will list all)")

    api_key_env = os.environ.get("DEPLOY_WATCH_APIKEYENV", "RENDER_DOT_COM_TOK")
    api_key = os.environ.get(api_key_env, "")
    _log.debug("API key env var: %s (%s)", api_key_env, "set" if api_key else "NOT SET")
    if not api_key:
        print(
            f"Error: environment variable {api_key_env} is not set. "
            f"Set it to your Render API key, or specify a different env var "
            f"name via apiKeyEnv in .deploy-watch.json.",
            file=sys.stderr,
        )
        sys.exit(1)

    return owner_id, api_key


def api_get(path, api_key):
    """Make an authenticated GET request to the Render API."""
    url = f"{RENDER_API_BASE}{path}"
    _log.debug("API GET %s", url)
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=SSL_CONTEXT) as resp:
            _log.debug("API response %s %s", resp.status, url)
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        _log.error("API HTTP %s for %s: %s", e.code, url, body[:200])
        print(f"Error: Render API returned {e.code}: {body}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        _log.error("API URLError for %s: %s\n%s", url, e.reason, traceback.format_exc())
        print(f"Error: could not reach Render API: {e.reason}", file=sys.stderr)
        sys.exit(1)


def fetch_services(api_key, owner_id=""):
    """Discover all web services, optionally filtered by owner/workspace."""
    params = "?type=web_service&limit=100"
    if owner_id:
        params += f"&ownerId={owner_id}"
    data = api_get(f"/services{params}", api_key)

    services = []
    if isinstance(data, list):
        for item in data:
            # API may return {service: {...}} wrappers or flat objects
            svc = item.get("service", item) if isinstance(item, dict) else item
            if svc.get("type") == "web_service":
                services.append(svc)

    _log.debug("Discovered %d web services", len(services))
    return services


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

_BRANCH_ENV_MAP = {
    "main": "prod",
    "master": "prod",
    "production": "prod",
    "staging": "staging",
    "stg": "staging",
    "dev": "dev",
    "develop": "dev",
}


def _infer_environment(branch: str) -> str:
    """Infer environment from the service's configured branch."""
    key = branch.lower().strip()
    return _BRANCH_ENV_MAP.get(key, key)


def iso_to_epoch(iso_str):
    """Convert an ISO 8601 timestamp to unix epoch string."""
    if not iso_str:
        return ""
    s = iso_str.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
        return str(int(dt.timestamp()))
    except (ValueError, TypeError):
        return ""


def _unwrap_deploys(deploys_raw):
    """Unwrap deploy objects from API response."""
    deploys = []
    if isinstance(deploys_raw, list):
        for item in deploys_raw:
            if isinstance(item, dict) and "deploy" in item:
                deploys.append(item["deploy"])
            else:
                deploys.append(item)
    return deploys


def _build_record(deploy, svc_id, svc_name, svc_url, environment):
    """Build a single deploy record dict."""
    status_raw = deploy.get("status", "")
    mapped_status = STATUS_MAP.get(status_raw, status_raw)

    commit_obj = deploy.get("commit", {}) or {}
    created_at = iso_to_epoch(deploy.get("createdAt"))
    finished_at = iso_to_epoch(deploy.get("finishedAt"))

    commit_id = commit_obj.get("id", "")
    commit_msg = (commit_obj.get("message", "") or "").split("\n")[0]

    deploy_id = deploy.get("id", "")

    record = {
        "commit": commit_id[:7] if commit_id else "",
        "tag": "",
        "message": commit_msg,
        "author": deploy.get("creator", {}).get("name", "")
                  or deploy.get("creator", {}).get("email", ""),
        "environment": environment,
        "service_name": svc_name,
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

    # Timestamps
    record["build_started"] = created_at
    if mapped_status == "live" and finished_at:
        record["deploy_finished"] = finished_at
    else:
        record["deploy_finished"] = ""

    if svc_url:
        record["service_url"] = svc_url

    # Render deploy dashboard URL
    if deploy_id:
        record["deploy_url"] = (
            f"https://dashboard.render.com/web/{svc_id}/deploys/{deploy_id}"
        )

    return record


def cmd_name():
    print("Render")


def cmd_config():
    config = {
        "fields": [
            {
                "key": "ownerId",
                "label": "Owner/Team ID (tea-xxx, optional)",
                "required": False,
                "default": "",
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
    owner_id, api_key = get_config_from_env()

    services = fetch_services(api_key, owner_id)
    if not services:
        _log.debug("No web services found")
        return

    # Collect deploys from all services with sort key
    all_deploys = []  # (iso_timestamp, record)

    for svc in services:
        svc_id = svc["id"]
        svc_name = svc.get("name", "")
        svc_url = (
            svc.get("serviceDetails", {}).get("url", "")
            or svc.get("url", "")
        )
        branch = svc.get("branch", "")
        environment = _infer_environment(branch)

        try:
            deploys_raw = api_get(
                f"/services/{svc_id}/deploys?limit={DEPLOYS_PER_SERVICE}",
                api_key,
            )
        except SystemExit:
            _log.warning("Failed to fetch deploys for %s (non-fatal)", svc_id)
            continue

        for deploy in _unwrap_deploys(deploys_raw):
            record = _build_record(deploy, svc_id, svc_name, svc_url, environment)
            sort_key = deploy.get("createdAt", "")
            all_deploys.append((sort_key, record))

    # Sort by time descending, truncate
    all_deploys.sort(key=lambda x: x[0], reverse=True)
    for _, record in all_deploys[:MAX_TOTAL_RECORDS]:
        print(json.dumps(record))

    _log.debug("Emitted %d records from %d services",
               min(len(all_deploys), MAX_TOTAL_RECORDS), len(services))


def main():
    _log.debug("--- invoked: %s", " ".join(sys.argv))

    if len(sys.argv) < 2:
        _log.error("No command given")
        print("Usage: renderdotcom.py <name|config|list>", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    try:
        if cmd == "name":
            cmd_name()
        elif cmd == "config":
            cmd_config()
        elif cmd == "list":
            cmd_list()
        else:
            _log.error("Unknown command: %s", cmd)
            print(f"Error: unknown command '{cmd}'", file=sys.stderr)
            sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        _log.error("Unhandled exception:\n%s", traceback.format_exc())
        raise


if __name__ == "__main__":
    main()
