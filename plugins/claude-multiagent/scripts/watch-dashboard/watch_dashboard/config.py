"""Config file helpers for .deploy-watch.json.

Config schema
-------------
{
  "tabs": {
    "actions": {
      "enabled": true,          // bool — show/hide the Actions tab (default: true)
      "repo": "owner/repo"      // optional GitHub repo slug override
    },
    "deploys": {
      "enabled": true           // bool — show/hide the Deploys tab (default: true)
    }
  },
  "provider": "renderdotcom",   // deploy provider name (script in providers/)
  "renderdotcom": {             // provider-specific config keyed by provider name
    "serviceId": "srv-xxx",
    "apiKeyEnv": "RENDER_DOT_COM_TOK"
  }
}

All top-level keys other than "tabs" are the legacy provider config.
The "tabs" key is optional — when absent both tabs are enabled with auto-detected settings.
"""

from __future__ import annotations

import json
import logging
import os

_log = logging.getLogger("watch-dashboard")


def config_read(config_file: str) -> dict:
    """Read and parse the config file. Returns dict or empty dict."""
    try:
        with open(config_file, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def config_write(config_file: str, data: dict) -> None:
    """Write config data to the config file."""
    with open(config_file, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def config_get_provider(config_file: str) -> str | None:
    """Return the configured provider name, or None."""
    cfg = config_read(config_file)
    return cfg.get("provider") or None


def config_remove(config_file: str) -> None:
    """Remove the config file entirely."""
    try:
        os.remove(config_file)
    except FileNotFoundError:
        pass


# ---------------------------------------------------------------------------
# Tab-level config helpers
# ---------------------------------------------------------------------------


def config_get_tab(config_file: str, tab: str) -> dict:
    """Return the config dict for a specific tab (actions or deploys).

    Falls back to ``{}`` if the tab key is missing.  The ``enabled`` field
    defaults to ``True`` when absent so existing configs without a "tabs"
    section continue to show both tabs.
    """
    cfg = config_read(config_file)
    return cfg.get("tabs", {}).get(tab, {})


def config_tab_enabled(config_file: str, tab: str) -> bool:
    """Return True if the given tab is enabled (default: True)."""
    tab_cfg = config_get_tab(config_file, tab)
    return bool(tab_cfg.get("enabled", True))


def config_set_tab(config_file: str, tab: str, tab_cfg: dict) -> None:
    """Merge *tab_cfg* into the tab's config section and persist."""
    cfg = config_read(config_file)
    tabs = cfg.setdefault("tabs", {})
    existing = tabs.get(tab, {})
    existing.update(tab_cfg)
    tabs[tab] = existing
    config_write(config_file, cfg)
