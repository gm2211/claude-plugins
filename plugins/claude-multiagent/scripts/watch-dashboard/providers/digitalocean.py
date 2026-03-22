#!/usr/bin/env python3
"""DigitalOcean App Platform deploy provider for deploy-watch.

Auto-discovers all apps and fetches recent deployments for each,
returning interleaved JSON-line records sorted by time.
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
# Debug logging — writes to /tmp/deploy-watch-digitalocean.log
# ---------------------------------------------------------------------------

_log = logging.getLogger("deploy-watch-digitalocean")
_log.setLevel(logging.DEBUG)
_log.propagate = False
if not _log.handlers:
    import tempfile
    _log_path = os.path.join(tempfile.gettempdir(), "deploy-watch-digitalocean.log")
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
except (ImportError, AttributeError):
    SSL_CONTEXT = None

DO_API_BASE = "https://api.digitalocean.com/v2"
TIMEOUT = 10
DEPLOYS_PER_APP = 5
MAX_TOTAL_RECORDS = 20


def get_config_from_env():
    """Read provider config from DEPLOY_WATCH_* environment variables."""
    api_key_env = os.environ.get("DEPLOY_WATCH_APIKEYENV", "DIGITALOCEAN_API_TOKEN")
    api_key = os.environ.get(api_key_env, "")
    _log.debug("API key env var: %s (%s)", api_key_env, "set" if api_key else "NOT SET")
    if not api_key:
        print(
            f"Error: environment variable {api_key_env} is not set. "
            f"Set it to your DigitalOcean API token, or specify a different env var "
            f"name via apiKeyEnv in .deploy-watch.json.",
            file=sys.stderr,
        )
        sys.exit(1)
    return api_key


def api_get(path, api_key):
    """Make an authenticated GET request to the DigitalOcean API."""
    url = f"{DO_API_BASE}{path}"
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
        print(f"Error: DigitalOcean API returned {e.code}: {body}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        _log.error("API URLError for %s: %s", url, e.reason)
        print(f"Error: could not reach DigitalOcean API: {e.reason}", file=sys.stderr)
        sys.exit(1)


def fetch_apps(api_key):
    """List all apps."""
    data = api_get("/apps", api_key)
    apps = data.get("apps", [])
    _log.debug("Discovered %d apps", len(apps))
    return apps


# ---------------------------------------------------------------------------
# Phase/status mapping
# ---------------------------------------------------------------------------

def _map_phase(phase):
    """Map DO deployment phase to (build_status, deploy_status)."""
    phase = (phase or "").upper()
    mapping = {
        "PENDING_BUILD": ("pending", "pending"),
        "BUILDING": ("building", "pending"),
        "PENDING_DEPLOY": ("success", "pending"),
        "DEPLOYING": ("success", "deploying"),
        "ACTIVE": ("success", "live"),
        "ERROR": ("failed", "failed"),
        "CANCELED": ("cancelled", "cancelled"),
        "SUPERSEDED": ("cancelled", "cancelled"),
    }
    return mapping.get(phase, (phase.lower(), phase.lower()))


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


def _extract_commit_info(deployment):
    """Extract commit hash and message from a DO deployment object."""
    # Try deployment.spec.services[*].github.deploy_on_push or git source
    spec = deployment.get("spec", {}) or {}
    commit_hash = ""
    commit_msg = ""

    # Check cause for commit info
    cause = deployment.get("cause", "")
    if cause:
        commit_msg = cause

    # Walk through services/static_sites/workers to find git source info
    for component_type in ("services", "static_sites", "workers", "jobs"):
        for component in spec.get(component_type, []) or []:
            for source_type in ("github", "gitlab", "git"):
                source = component.get(source_type, {}) or {}
                if source.get("branch"):
                    # Branch info is here but commit hash is in the deployment itself
                    pass

    # The commit hash is often in the deployment's commit field or services
    services = deployment.get("services", []) or []
    for svc in services:
        source_commit = svc.get("source_commit_hash", "")
        if source_commit:
            commit_hash = source_commit
            break

    # Also check top-level
    if not commit_hash:
        commit_hash = deployment.get("commit_hash", "")

    return commit_hash, commit_msg


def _infer_environment(app):
    """Infer environment from app spec or tier."""
    spec = app.get("spec", {}) or {}
    # Check for explicit environment in spec name
    name = spec.get("name", "") or app.get("spec", {}).get("name", "")
    name_lower = name.lower()
    if "prod" in name_lower or "production" in name_lower:
        return "prod"
    if "staging" in name_lower or "stg" in name_lower:
        return "staging"
    if "dev" in name_lower or "preview" in name_lower:
        return "dev"

    # Check tier
    tier = (app.get("tier_slug", "") or "").lower()
    if "basic" in tier or "professional" in tier or "pro" in tier:
        return "prod"
    if "starter" in tier:
        return "dev"

    return ""


def _build_record(deployment, app_id, app_name, app_url, environment):
    """Build a single deploy record dict."""
    phase = deployment.get("phase", "")
    build_status, deploy_status = _map_phase(phase)

    commit_hash, commit_msg = _extract_commit_info(deployment)
    created_at = iso_to_epoch(deployment.get("created_at"))
    updated_at = iso_to_epoch(deployment.get("updated_at"))

    deploy_id = deployment.get("id", "")

    record = {
        "commit": commit_hash[:7] if commit_hash else "",
        "tag": "",
        "message": commit_msg.split("\n")[0] if commit_msg else "",
        "author": "",
        "environment": environment,
        "service_name": app_name,
        "build_status": build_status,
        "deploy_status": deploy_status,
        "build_started": created_at,
    }

    # Only set deploy_finished for terminal phases
    if phase and phase.upper() in ("ACTIVE", "ERROR", "CANCELED", "SUPERSEDED"):
        record["deploy_finished"] = updated_at
    else:
        record["deploy_finished"] = ""

    if app_url:
        record["service_url"] = app_url

    if deploy_id:
        record["deploy_url"] = (
            f"https://cloud.digitalocean.com/apps/{app_id}/deployments/{deploy_id}"
        )

    return record


def cmd_name():
    print("DigitalOcean")


def cmd_config():
    config = {
        "fields": [
            {
                "key": "apiKeyEnv",
                "label": "API Key env var",
                "required": False,
                "default": "DIGITALOCEAN_API_TOKEN",
            },
        ]
    }
    print(json.dumps(config))


def cmd_list():
    api_key = get_config_from_env()

    apps = fetch_apps(api_key)
    if not apps:
        _log.debug("No apps found")
        return

    all_deploys = []  # (iso_timestamp, record)

    for app in apps:
        app_id = app.get("id", "")
        spec = app.get("spec", {}) or {}
        app_name = spec.get("name", "") or app_id
        app_url = app.get("live_url", "") or app.get("default_ingress", "")
        environment = _infer_environment(app)

        try:
            data = api_get(
                f"/apps/{app_id}/deployments?per_page={DEPLOYS_PER_APP}",
                api_key,
            )
        except SystemExit:
            _log.warning("Failed to fetch deployments for %s (non-fatal)", app_id)
            continue

        deployments = data.get("deployments", []) or []
        _log.debug("App %s (%s): %d deployments", app_name, app_id, len(deployments))

        for deployment in deployments:
            record = _build_record(deployment, app_id, app_name, app_url, environment)
            sort_key = deployment.get("created_at", "")
            all_deploys.append((sort_key, record))

    # Sort by time descending, truncate
    all_deploys.sort(key=lambda x: x[0], reverse=True)
    for _, record in all_deploys[:MAX_TOTAL_RECORDS]:
        print(json.dumps(record))

    _log.debug("Emitted %d records from %d apps",
               min(len(all_deploys), MAX_TOTAL_RECORDS), len(apps))


def main():
    _log.debug("--- invoked: %s", " ".join(sys.argv))

    if len(sys.argv) < 2:
        _log.error("No command given")
        print("Usage: digitalocean.py <name|config|list>", file=sys.stderr)
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
