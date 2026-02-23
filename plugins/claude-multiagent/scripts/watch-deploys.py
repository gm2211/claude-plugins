#!/usr/bin/env python3
"""Deploy Watch TUI — curses-based dashboard for monitoring deployments.

Replaces the bash watch-deploys.sh with a Python curses implementation.
Uses only the standard library.

Keys: p = provider config, r = refresh, d = disable pane, q = quit, ? = help
"""

import curses
import json
import logging
import os
import shutil
import subprocess
import sys
import threading
import time

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

POLL_INTERVAL = 30
SPINNER_CHARS = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

# ---------------------------------------------------------------------------
# Debug logging — writes to /tmp/deploy-watch-tui.log
# ---------------------------------------------------------------------------

_log = logging.getLogger("deploy-watch-tui")
_log.setLevel(logging.DEBUG)
_log.propagate = False
if not _log.handlers:
    _fh = logging.FileHandler("/tmp/deploy-watch-tui.log")
    _fh.setFormatter(logging.Formatter(
        "%(asctime)s %(levelname)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    ))
    _log.addHandler(_fh)

# Determine paths at startup using absolute references
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROVIDERS_DIR = os.path.join(SCRIPT_DIR, "providers")

# Project directory: walk up from SCRIPT_DIR to find the git root,
# or fall back to cwd. This ensures the config path is always absolute.
def _find_project_dir():
    """Find the project root directory (git root or cwd)."""
    # Try git rev-parse first
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return os.getcwd()

PROJECT_DIR = sys.argv[1] if len(sys.argv) > 1 else _find_project_dir()
CONFIG_FILE = os.path.join(PROJECT_DIR, ".deploy-watch.json")


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

def config_read():
    """Read and parse the config file. Returns dict or empty dict."""
    try:
        with open(CONFIG_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def config_write(data):
    """Write config data to the config file."""
    with open(CONFIG_FILE, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def config_get_provider():
    """Return the configured provider name, or None."""
    cfg = config_read()
    return cfg.get("provider") or None


def config_remove():
    """Remove the config file entirely."""
    try:
        os.remove(CONFIG_FILE)
    except FileNotFoundError:
        pass


# ---------------------------------------------------------------------------
# Provider helpers
# ---------------------------------------------------------------------------

def list_providers():
    """List available provider scripts (executable files in providers dir)."""
    providers = []
    if not os.path.isdir(PROVIDERS_DIR):
        return providers
    for fname in sorted(os.listdir(PROVIDERS_DIR)):
        fpath = os.path.join(PROVIDERS_DIR, fname)
        if not os.path.isfile(fpath) or not os.access(fpath, os.X_OK):
            continue
        # Skip READMEs and markdown
        if fname.startswith("README") or fname.endswith(".md"):
            continue
        providers.append(fname)
    return providers


def provider_display_name(provider):
    """Get the human-readable name of a provider."""
    script = os.path.join(PROVIDERS_DIR, provider)
    if not os.access(script, os.X_OK):
        return provider
    try:
        result = subprocess.run(
            [script, "name"], capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return provider


def provider_config_fields(provider):
    """Get config fields for a provider. Returns list of dicts with
    keys: key, label, required, default."""
    script = os.path.join(PROVIDERS_DIR, provider)
    if not os.access(script, os.X_OK):
        return []
    try:
        result = subprocess.run(
            [script, "config"], capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return []
        data = json.loads(result.stdout)
        fields = data.get("fields", [])
        # Normalize fields
        for f in fields:
            f.setdefault("required", False)
            f.setdefault("default", "")
        return fields
    except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError):
        return []


def fetch_deploys():
    """Call the configured provider's list command and return parsed records."""
    cfg = config_read()
    provider = cfg.get("provider")
    if not provider:
        _log.debug("fetch_deploys: no provider configured")
        return []

    script = os.path.join(PROVIDERS_DIR, provider)
    if not os.access(script, os.X_OK):
        _log.warning("fetch_deploys: provider script not executable: %s", script)
        return []

    # Build env vars from provider config section
    fields = provider_config_fields(provider)
    env = os.environ.copy()
    provider_cfg = cfg.get(provider, {})

    for field in fields:
        key = field["key"]
        val = provider_cfg.get(key, field.get("default", ""))
        env_key = f"DEPLOY_WATCH_{key.upper()}"
        env[env_key] = str(val)

    _log.debug("fetch_deploys: calling %s list", script)
    try:
        result = subprocess.run(
            [script, "list"], capture_output=True, text=True,
            timeout=30, env=env
        )
        _log.debug("fetch_deploys: returncode=%d", result.returncode)
        if result.stderr.strip():
            _log.debug("fetch_deploys: stderr: %s", result.stderr.strip())
        if result.returncode != 0:
            _log.warning("fetch_deploys: provider exited %d", result.returncode)
            return None
        records = []
        for line in result.stdout.strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                _log.warning("fetch_deploys: bad JSON line: %s", line[:120])
                continue
        _log.debug("fetch_deploys: parsed %d records", len(records))
        return records
    except subprocess.TimeoutExpired:
        _log.error("fetch_deploys: provider timed out after 30s")
        return None
    except FileNotFoundError:
        _log.error("fetch_deploys: provider script not found: %s", script)
        return None


# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

def elapsed_since(start_epoch):
    """Format elapsed time from a unix epoch to now."""
    try:
        start = int(start_epoch)
    except (ValueError, TypeError):
        return str(start_epoch)
    diff = max(0, int(time.time()) - start)
    if diff < 60:
        return f"{diff}s"
    elif diff < 3600:
        return f"{diff // 60}m {diff % 60}s"
    else:
        return f"{diff // 3600}h {(diff % 3600) // 60}m"


def format_elapsed(record):
    """Format the elapsed/duration column for a deploy record."""
    build_started = record.get("build_started", "")
    deploy_finished = record.get("deploy_finished", "")

    if not build_started:
        return ""

    try:
        start = int(build_started)
    except (ValueError, TypeError):
        return str(build_started)

    if deploy_finished:
        try:
            end = int(deploy_finished)
            dur = max(0, end - start)
            if dur < 60:
                return f"{dur}s"
            elif dur < 3600:
                return f"{dur // 60}m {dur % 60}s"
            else:
                return f"{dur // 3600}h {(dur % 3600) // 60}m"
        except (ValueError, TypeError):
            pass

    return f"{elapsed_since(build_started)} ago"


# ---------------------------------------------------------------------------
# fswatch integration
# ---------------------------------------------------------------------------

class FsWatcher:
    """Watch .git/refs/remotes/ and config file for changes using fswatch."""

    def __init__(self):
        self._triggered = threading.Event()
        self._process = None
        self._thread = None

    def start(self):
        git_refs = os.path.join(PROJECT_DIR, ".git", "refs", "remotes")
        if not os.path.isdir(git_refs):
            return
        if not shutil.which("fswatch"):
            return

        watch_paths = [git_refs, CONFIG_FILE]
        try:
            self._process = subprocess.Popen(
                ["fswatch", "--latency", "1", "--one-per-batch"] + watch_paths,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
            )
        except FileNotFoundError:
            return

        self._thread = threading.Thread(target=self._reader, daemon=True)
        self._thread.start()

    def _reader(self):
        if not self._process or not self._process.stdout:
            return
        for _ in self._process.stdout:
            self._triggered.set()

    def check(self):
        """Return True if a change was detected since last check."""
        if self._triggered.is_set():
            self._triggered.clear()
            return True
        return False

    def stop(self):
        if self._process:
            try:
                self._process.terminate()
                self._process.wait(timeout=2)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    self._process.kill()
                except ProcessLookupError:
                    pass


# ---------------------------------------------------------------------------
# TUI Application
# ---------------------------------------------------------------------------

class DeployWatchApp:
    """Main curses-based TUI application."""

    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.cached_records = []
        self.show_help = False
        self.show_provider_menu = False
        self.show_provider_manage = False
        self.spinner_idx = 0
        self.last_fetch_time = 0
        self.is_fetching = False
        self.fetch_error = ""
        self.fswatch = FsWatcher()

        # Setup curses
        curses.curs_set(0)  # Hide cursor
        curses.use_default_colors()
        curses.halfdelay(20)  # 2 second timeout for getch (20 tenths)

        # Initialize color pairs
        if curses.has_colors():
            curses.init_pair(1, curses.COLOR_GREEN, -1)    # success/live
            curses.init_pair(2, curses.COLOR_YELLOW, -1)    # building/pending
            curses.init_pair(3, curses.COLOR_RED, -1)       # failed
            curses.init_pair(4, curses.COLOR_CYAN, -1)      # info/url
            curses.init_pair(5, curses.COLOR_WHITE, -1)     # header

    def spinner(self):
        """Return current spinner character and advance."""
        ch = SPINNER_CHARS[self.spinner_idx]
        self.spinner_idx = (self.spinner_idx + 1) % len(SPINNER_CHARS)
        return ch

    def status_color(self, status):
        """Return curses color pair for a status string."""
        if status in ("live", "success"):
            return curses.color_pair(1)
        elif status in ("building", "deploying", "pending"):
            return curses.color_pair(2)
        elif status == "failed":
            return curses.color_pair(3)
        elif status == "cancelled":
            return curses.A_DIM
        return 0

    def status_display(self, status):
        """Return display string for status (with spinner for active)."""
        if status in ("building", "deploying", "pending"):
            return f"{status} {self.spinner()}"
        return status

    # --- Refresh ---

    def do_refresh(self):
        """Fetch deploy data from the provider."""
        _log.debug("do_refresh: starting")
        self.is_fetching = True
        self.fetch_error = ""
        try:
            records = fetch_deploys()
            if records is None:
                # Provider failure — keep cached data, show error indicator
                self.fetch_error = "Provider error"
            else:
                # Success (possibly empty) — update cached data
                self.cached_records = records
            self.last_fetch_time = int(time.time())
            _log.debug("do_refresh: got %s records", len(records) if records is not None else "None")
        except Exception as e:
            self.fetch_error = str(e)
            _log.error("do_refresh: exception: %s", e)
        finally:
            self.is_fetching = False

    # --- Rendering ---

    def safe_addstr(self, y, x, text, attr=0):
        """Write text to screen, clipping to window bounds."""
        max_y, max_x = self.stdscr.getmaxyx()
        if y < 0 or y >= max_y or x >= max_x:
            return
        # Clip text to fit
        available = max_x - x
        if available <= 0:
            return
        text = text[:available]
        try:
            self.stdscr.addstr(y, x, text, attr)
        except curses.error:
            pass  # Ignore write errors at screen edge

    def render_header(self, row):
        """Render the title header. Returns next row."""
        self.safe_addstr(row, 2, "Deploy Watch", curses.A_BOLD | curses.color_pair(5))
        row += 1

        # Show provider info if configured
        provider = config_get_provider()
        if provider:
            name = provider_display_name(provider)
            self.safe_addstr(row, 2, "Provider: ", curses.A_DIM)
            self.safe_addstr(row, 12, name, curses.color_pair(4))
        row += 1

        return row

    def render_footer(self, row):
        """Render the status bar at bottom."""
        max_y, max_x = self.stdscr.getmaxyx()
        footer_row = max_y - 1

        ts = time.strftime("%H:%M:%S")
        if self.is_fetching:
            status = f"Fetching {self.spinner()}  |  "
        elif self.fetch_error:
            status = f"Error: {self.fetch_error}  |  "
        else:
            status = f"Updated {ts}  |  "

        footer = f"{status}[p]rovider  [r]efresh  [d]isable  [?]help  [q]uit"
        attr = curses.A_DIM
        if self.fetch_error and not self.is_fetching:
            attr = curses.color_pair(3)  # red
        self.safe_addstr(footer_row, 0, footer, attr)

    def render_unconfigured(self, row):
        """Render the 'not configured' screen. Returns next row."""
        self.safe_addstr(row, 2, "NOT CONFIGURED", curses.A_BOLD | curses.color_pair(2))
        row += 2
        self.safe_addstr(row, 2, "Press [p] to select a deployment provider and configure.")
        row += 2

        providers = list_providers()
        if providers:
            self.safe_addstr(row, 2, f"Available providers: {', '.join(providers)}")
        else:
            self.safe_addstr(row, 2, f"No providers found in {PROVIDERS_DIR}")
        row += 2

        self.safe_addstr(row, 2, "Or create ", curses.A_DIM)
        self.safe_addstr(row, 12, ".deploy-watch.json", curses.color_pair(4))
        self.safe_addstr(row, 30, " manually.", curses.A_DIM)
        row += 1

        return row

    def render_table(self, row):
        """Render the deploy table. Returns next row."""
        records = self.cached_records
        if not records:
            self.safe_addstr(row, 2, "No deploy data available.", curses.A_DIM)
            return row + 1

        max_y, max_x = self.stdscr.getmaxyx()

        # Show service URL if present
        service_url = ""
        for rec in records:
            if rec.get("service_url"):
                service_url = rec["service_url"]
                break

        if service_url:
            self.safe_addstr(row, 2, service_url, curses.color_pair(4))
            row += 2

        # Build table data
        headers = ["Commit", "Message", "Build", "Deploy", "Elapsed"]
        table_rows = []
        for rec in records:
            commit = rec.get("commit", "")[:7]
            msg = rec.get("message", "")
            if len(msg) > 40:
                msg = msg[:38] + ".."
            build = rec.get("build_status", "")
            deploy = rec.get("deploy_status", "")
            elapsed = format_elapsed(rec)
            table_rows.append([commit, msg, build, deploy, elapsed])

        # Calculate column widths
        widths = [len(h) for h in headers]
        for tr in table_rows:
            for i, cell in enumerate(tr):
                widths[i] = max(widths[i], len(cell))
                # Account for spinner chars in status columns
                if i in (2, 3) and cell in ("building", "deploying", "pending"):
                    widths[i] = max(widths[i], len(cell) + 2)

        # Add padding (1 char each side)
        widths = [w + 2 for w in widths]

        # Shrink to fit terminal width
        total = sum(widths) + len(widths) + 1  # separators
        if total > max_x:
            excess = total - max_x
            # Shrink message column first
            if widths[1] > 12:
                can_shrink = min(widths[1] - 12, excess)
                widths[1] -= can_shrink
                excess -= can_shrink
            # Then shrink widest columns
            while excess > 0:
                widest = -1
                widest_w = 0
                for i in range(5):
                    if widths[i] > 6 and widths[i] > widest_w:
                        widest = i
                        widest_w = widths[i]
                if widest < 0:
                    break
                widths[widest] -= 1
                excess -= 1

        # Draw top border
        top = "\u250c"
        for i, w in enumerate(widths):
            top += "\u2500" * w
            top += "\u252c" if i < len(widths) - 1 else "\u2510"
        self.safe_addstr(row, 0, top)
        row += 1

        # Draw header row
        x = 0
        self.safe_addstr(row, x, "\u2502")
        x += 1
        for i, h in enumerate(headers):
            w = widths[i]
            pad_left = (w - len(h)) // 2
            pad_right = w - len(h) - pad_left
            self.safe_addstr(row, x, " " * pad_left)
            self.safe_addstr(row, x + pad_left, h, curses.A_BOLD)
            self.safe_addstr(row, x + pad_left + len(h), " " * pad_right)
            x += w
            self.safe_addstr(row, x, "\u2502")
            x += 1
        row += 1

        # Draw mid border
        mid = "\u251c"
        for i, w in enumerate(widths):
            mid += "\u2500" * w
            mid += "\u253c" if i < len(widths) - 1 else "\u2524"
        self.safe_addstr(row, 0, mid)
        row += 1

        # Draw data rows
        for tr in table_rows:
            if row >= max_y - 2:
                break
            x = 0
            self.safe_addstr(row, x, "\u2502")
            x += 1
            for i, cell in enumerate(tr):
                w = widths[i]
                max_content = w - 2
                if max_content < 1:
                    max_content = 1

                # Truncate
                display = cell
                if len(display) > max_content:
                    if max_content >= 3:
                        display = display[:max_content - 2] + ".."
                    else:
                        display = display[:max_content]

                # Status columns get color and spinner
                if i in (2, 3):
                    status_text = self.status_display(cell)
                    if len(status_text) > max_content:
                        status_text = status_text[:max_content]
                    attr = self.status_color(cell)
                    self.safe_addstr(row, x, " ")
                    self.safe_addstr(row, x + 1, status_text, attr)
                    pad = w - 1 - len(status_text)
                    if pad > 0:
                        self.safe_addstr(row, x + 1 + len(status_text), " " * pad)
                else:
                    self.safe_addstr(row, x, " " + display)
                    pad = w - 1 - len(display)
                    if pad > 0:
                        self.safe_addstr(row, x + 1 + len(display), " " * pad)

                x += w
                self.safe_addstr(row, x, "\u2502")
                x += 1
            row += 1

        # Draw bottom border
        bot = "\u2514"
        for i, w in enumerate(widths):
            bot += "\u2500" * w
            bot += "\u2534" if i < len(widths) - 1 else "\u2518"
        self.safe_addstr(row, 0, bot)
        row += 1

        return row

    def render_help(self, row):
        """Render help overlay. Returns next row."""
        row += 1
        self.safe_addstr(row, 2, "Keyboard Shortcuts", curses.A_BOLD)
        row += 2
        shortcuts = [
            ("p", "Select/configure deployment provider"),
            ("r", "Force refresh deploy data"),
            ("d", "Disable deploy pane for this project"),
            ("q", "Quit"),
            ("?", "Toggle this help"),
        ]
        for key, desc in shortcuts:
            self.safe_addstr(row, 2, key, curses.A_BOLD)
            self.safe_addstr(row, 4, f"  {desc}")
            row += 1
        row += 1
        self.safe_addstr(row, 2, "Press any key to dismiss.")
        row += 1
        return row

    def render_provider_menu(self, row):
        """Render provider selection menu. Returns next row."""
        row += 1
        self.safe_addstr(row, 2, "Select a Provider", curses.A_BOLD)
        row += 2

        providers = list_providers()
        if not providers:
            self.safe_addstr(row, 2, "No providers available.")
            row += 1
            self.safe_addstr(row, 2, f"Add provider scripts to: {PROVIDERS_DIR}")
            row += 2
            self.safe_addstr(row, 2, "Press any key to go back.")
            return row + 1

        for idx, p in enumerate(providers, 1):
            name = provider_display_name(p)
            self.safe_addstr(row, 2, f"{idx}", curses.A_BOLD)
            self.safe_addstr(row, 3 + len(str(idx)), f") {name}")
            row += 1

        row += 1
        self.safe_addstr(row, 2, "Enter number (or q to cancel): ")
        row += 1
        return row

    def render_provider_manage(self, row):
        """Render provider management menu (change/remove). Returns next row."""
        row += 1
        provider = config_get_provider()
        name = provider_display_name(provider) if provider else "unknown"

        self.safe_addstr(row, 2, f"Current provider: ", curses.A_DIM)
        self.safe_addstr(row, 20, name, curses.color_pair(4) | curses.A_BOLD)
        row += 2
        self.safe_addstr(row, 2, "[c]", curses.A_BOLD)
        self.safe_addstr(row, 5, " Change provider  ")
        self.safe_addstr(row, 23, "[r]", curses.A_BOLD)
        self.safe_addstr(row, 26, " Remove provider  ")
        self.safe_addstr(row, 44, "[q]", curses.A_BOLD)
        self.safe_addstr(row, 47, " Cancel")
        row += 1
        return row

    def render_screen(self):
        """Full screen render."""
        self.stdscr.erase()
        row = 0

        row = self.render_header(row)

        if self.show_help:
            self.render_help(row)
        elif self.show_provider_menu:
            self.render_provider_menu(row)
        elif self.show_provider_manage:
            self.render_provider_manage(row)
        else:
            provider = config_get_provider()
            if not provider:
                self.render_unconfigured(row)
            else:
                self.render_table(row)

        self.render_footer(0)

        try:
            self.stdscr.refresh()
        except curses.error:
            pass

    # --- Interactive configuration ---

    def configure_provider_interactive(self, provider):
        """Interactive provider configuration using curses.

        Temporarily switches to line-input mode to collect field values.
        Returns True if config was saved successfully.
        """
        curses.curs_set(1)  # Show cursor
        curses.echo()
        curses.nocbreak()
        self.stdscr.keypad(False)

        self.stdscr.erase()
        row = 0
        name = provider_display_name(provider)
        self.safe_addstr(row, 2, f"Configuring {name}", curses.A_BOLD)
        row += 2

        fields = provider_config_fields(provider)
        values = {}

        for field in fields:
            key = field["key"]
            label = field.get("label", key)
            default = field.get("default", "")
            required = field.get("required", False)

            prompt = f"  {label}"
            if default:
                prompt += f" [{default}]"
            prompt += ": "

            self.safe_addstr(row, 0, prompt)
            self.stdscr.refresh()

            # Read input
            try:
                curses.echo()
                input_bytes = self.stdscr.getstr(row, len(prompt), 200)
                val = input_bytes.decode("utf-8", errors="replace").strip()
            except (curses.error, UnicodeDecodeError):
                val = ""

            if not val and default:
                val = default

            if required and not val:
                row += 1
                self.safe_addstr(row, 2, "Required field cannot be empty.",
                                 curses.color_pair(3))
                self.stdscr.refresh()
                time.sleep(1.5)
                # Restore curses state
                curses.noecho()
                curses.cbreak()
                curses.curs_set(0)
                self.stdscr.keypad(True)
                curses.halfdelay(20)
                return False

            values[key] = val
            row += 1

        # Write config
        cfg = {
            "provider": provider,
            provider: values,
        }
        config_write(cfg)

        row += 1
        self.safe_addstr(row, 2, f"Configuration saved to {CONFIG_FILE}",
                         curses.color_pair(1))
        self.stdscr.refresh()
        time.sleep(1)

        # Restore curses state
        curses.noecho()
        curses.cbreak()
        curses.curs_set(0)
        self.stdscr.keypad(True)
        curses.halfdelay(20)
        return True

    # --- Disable deploy pane ---

    def disable_deploy_pane(self):
        """Disable the deploy pane for this project and exit."""
        config_path = os.path.join(PROJECT_DIR, ".claude", "claude-multiagent.local.md")
        os.makedirs(os.path.dirname(config_path), exist_ok=True)

        # Read existing content to avoid duplicates
        existing = ""
        try:
            with open(config_path, "r") as f:
                existing = f.read()
        except FileNotFoundError:
            pass

        if "deploy_pane: disabled" not in existing:
            with open(config_path, "a") as f:
                if existing and not existing.endswith("\n"):
                    f.write("\n")
                f.write("deploy_pane: disabled\n")

        # Show confirmation briefly before exiting
        self.stdscr.erase()
        self.safe_addstr(2, 2, "Deploy pane disabled for this project.", curses.A_BOLD | curses.color_pair(1))
        self.safe_addstr(4, 2, "Re-enable: remove 'deploy_pane: disabled' from")
        self.safe_addstr(5, 2, f"  {config_path}", curses.color_pair(4))
        self.safe_addstr(7, 2, "Exiting in 3 seconds...", curses.A_DIM)
        try:
            self.stdscr.refresh()
        except curses.error:
            pass
        time.sleep(3)

        # Return False from run loop to exit, which closes the Zellij pane
        raise SystemExit(0)

    # --- Input handling ---

    def handle_input(self, key):
        """Handle a keypress. Returns False to quit, True to continue."""
        if key == -1:
            return True

        ch = None
        try:
            ch = chr(key)
        except (ValueError, OverflowError):
            return True

        # Help screen: any key dismisses
        if self.show_help:
            self.show_help = False
            return True

        # Provider management menu
        if self.show_provider_manage:
            if ch in ("q", "Q", "\x1b"):
                self.show_provider_manage = False
            elif ch in ("c", "C"):
                self.show_provider_manage = False
                self.show_provider_menu = True
            elif ch in ("r", "R"):
                config_remove()
                self.show_provider_manage = False
                self.cached_records = []
            return True

        # Provider selection menu
        if self.show_provider_menu:
            providers = list_providers()
            if ch in ("q", "Q", "\x1b"):
                self.show_provider_menu = False
                return True
            if ch.isdigit():
                idx = int(ch)
                if 1 <= idx <= len(providers):
                    selected = providers[idx - 1]
                    self.show_provider_menu = False
                    if self.configure_provider_interactive(selected):
                        self.do_refresh()
            return True

        # Main screen
        if ch in ("q", "Q"):
            return False
        elif ch == "?":
            self.show_help = True
        elif ch in ("p", "P"):
            # If provider configured, show manage menu; otherwise selection
            if config_get_provider():
                self.show_provider_manage = True
            else:
                self.show_provider_menu = True
        elif ch in ("r", "R"):
            self.do_refresh()
        elif ch in ("d", "D"):
            self.disable_deploy_pane()

        return True

    # --- Main loop ---

    def run(self):
        """Main event loop."""
        self.fswatch.start()

        # Initial fetch
        self.do_refresh()
        self.render_screen()

        last_poll = time.time()

        try:
            while True:
                # Non-blocking getch (halfdelay mode)
                try:
                    key = self.stdscr.getch()
                except curses.error:
                    key = -1

                if not self.handle_input(key):
                    break

                # Check poll / fswatch triggers
                now = time.time()
                if self.fswatch.check():
                    self.do_refresh()
                    last_poll = now
                elif now - last_poll >= POLL_INTERVAL:
                    self.do_refresh()
                    last_poll = now

                self.render_screen()
        finally:
            self.fswatch.stop()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(stdscr):
    # Force UTF-8
    import locale
    locale.setlocale(locale.LC_ALL, "")

    app = DeployWatchApp(stdscr)
    app.run()


if __name__ == "__main__":
    curses.wrapper(main)
