#!/usr/bin/env python3
"""GitHub Actions Watch TUI — curses-based dashboard for monitoring workflow runs.

Uses only the standard library.

Keys: r = refresh, q = quit, ? = help
"""

import argparse
import curses
import json
import locale
import logging
import os
import re
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

POLL_INTERVAL = 30
MAX_RUNS = 15
SPINNER_CHARS = ["|", "/", "-", "\\"]

# ---------------------------------------------------------------------------
# Debug logging — writes to /tmp/watch-gh-actions.log
# ---------------------------------------------------------------------------

_log = logging.getLogger("watch-gh-actions")
_log.setLevel(logging.DEBUG)
_log.propagate = False
if not _log.handlers:
    _fh = logging.FileHandler("/tmp/watch-gh-actions.log")
    _fh.setFormatter(logging.Formatter(
        "%(asctime)s %(levelname)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    ))
    _log.addHandler(_fh)


# ---------------------------------------------------------------------------
# Repo detection
# ---------------------------------------------------------------------------

def detect_repo():
    """Detect GitHub repo slug (owner/repo) from git remote origin."""
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return None
        remote_url = result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None

    # Handle https://github.com/owner/repo.git
    # Handle git@github.com:owner/repo.git
    match = re.search(r"github\.com[:/]([^/]+/[^/.]+)(\.git)?$", remote_url)
    if match:
        return match.group(1)
    return None


# ---------------------------------------------------------------------------
# Data fetching
# ---------------------------------------------------------------------------

def fetch_runs(repo):
    """Call gh run list and return parsed records, or None on error."""
    _log.debug("fetch_runs: repo=%s", repo)
    try:
        result = subprocess.run(
            [
                "gh", "run", "list",
                "--repo", repo,
                "--limit", str(MAX_RUNS),
                "--json",
                "headSha,workflowName,headBranch,status,conclusion,createdAt,updatedAt,url,databaseId",
            ],
            capture_output=True, text=True, timeout=30
        )
        _log.debug("fetch_runs: returncode=%d", result.returncode)
        if result.stderr.strip():
            _log.debug("fetch_runs: stderr: %s", result.stderr.strip())
        if result.returncode != 0:
            _log.warning("fetch_runs: gh exited %d: %s", result.returncode, result.stderr.strip())
            return None
        data = json.loads(result.stdout)
        _log.debug("fetch_runs: got %d runs", len(data))
        return data
    except subprocess.TimeoutExpired:
        _log.error("fetch_runs: timed out after 30s")
        return None
    except (FileNotFoundError, json.JSONDecodeError) as e:
        _log.error("fetch_runs: exception: %s", e)
        return None


# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

def parse_gh_time(ts):
    """Parse a GitHub ISO timestamp (2024-01-02T15:04:05Z) to epoch int."""
    if not ts:
        return None
    try:
        import calendar
        t = time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
        return int(calendar.timegm(t))
    except (ValueError, TypeError):
        return None


def fmt_duration(seconds):
    """Format a number of seconds as a human-readable duration."""
    if seconds is None or seconds < 0:
        return ""
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    elif seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    else:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"


def format_run_elapsed(run):
    """Return a formatted elapsed/duration string for a workflow run."""
    created_at = parse_gh_time(run.get("createdAt", ""))
    updated_at = parse_gh_time(run.get("updatedAt", ""))
    status = run.get("status", "")

    if created_at is None:
        return ""

    if status == "completed" and updated_at:
        duration = updated_at - created_at
        return fmt_duration(duration)
    else:
        # Running — show elapsed since created
        elapsed = int(time.time()) - created_at
        return fmt_duration(max(0, elapsed))


def map_status_color(status, conclusion):
    """Return (display_status, color_key) for a run."""
    if status == "completed":
        if conclusion == "success":
            return "success", "green"
        elif conclusion in ("failure", "timed_out", "startup_failure"):
            return conclusion or "failure", "red"
        elif conclusion in ("cancelled", "skipped", "stale"):
            return conclusion or "cancelled", "dim"
        else:
            return conclusion or status, "dim"
    elif status == "in_progress":
        return "in_progress", "yellow"
    elif status in ("queued", "waiting", "requested", "pending"):
        return status, "yellow"
    else:
        return status, "dim"


# ---------------------------------------------------------------------------
# TUI Application
# ---------------------------------------------------------------------------

class GHActionsApp:
    """Main curses-based TUI application."""

    def __init__(self, stdscr, repo=None):
        self.stdscr = stdscr
        self.repo = repo
        self.cached_runs = []
        self.show_help = False
        self.spinner_idx = 0
        self.last_fetch_time = 0
        self.is_fetching = False
        self.fetch_error = ""

        # Setup curses
        curses.curs_set(0)
        curses.use_default_colors()
        curses.halfdelay(10)  # 1-second timeout for getch (10 tenths)

        # Initialize color pairs
        if curses.has_colors():
            curses.init_pair(1, curses.COLOR_GREEN, -1)   # success
            curses.init_pair(2, curses.COLOR_YELLOW, -1)  # in_progress/queued
            curses.init_pair(3, curses.COLOR_RED, -1)     # failure
            curses.init_pair(4, curses.COLOR_CYAN, -1)    # info/header
            curses.init_pair(5, curses.COLOR_WHITE, -1)   # bold white

    def safe_addstr(self, y, x, text, attr=0):
        """Write text to screen, clipping to window bounds."""
        max_y, max_x = self.stdscr.getmaxyx()
        if y < 0 or y >= max_y or x >= max_x:
            return
        available = max_x - x
        if available <= 0:
            return
        text = str(text)[:available]
        try:
            self.stdscr.addstr(y, x, text, attr)
        except curses.error:
            pass

    def spinner(self):
        """Return current spinner character and advance."""
        ch = SPINNER_CHARS[self.spinner_idx % len(SPINNER_CHARS)]
        self.spinner_idx += 1
        return ch

    def color_attr(self, color_key, extra=0):
        """Return curses attribute for a color key."""
        if not curses.has_colors():
            return extra
        mapping = {
            "green": curses.color_pair(1),
            "yellow": curses.color_pair(2),
            "red": curses.color_pair(3),
            "cyan": curses.color_pair(4),
            "white": curses.color_pair(5),
            "dim": curses.A_DIM,
        }
        return mapping.get(color_key, 0) | extra

    # --- Refresh ---

    def do_refresh(self):
        """Fetch workflow run data from GitHub."""
        _log.debug("do_refresh: repo=%s", self.repo)
        self.is_fetching = True
        self.fetch_error = ""
        try:
            if not self.repo:
                self.repo = detect_repo()
                _log.debug("do_refresh: detected repo=%s", self.repo)
            if not self.repo:
                self.fetch_error = "Could not detect repo. Use --repo owner/name."
                return

            runs = fetch_runs(self.repo)
            if runs is None:
                self.fetch_error = "gh run list failed — check gh auth and repo."
            else:
                self.cached_runs = runs
            self.last_fetch_time = int(time.time())
            _log.debug("do_refresh: cached %d runs", len(self.cached_runs))
        except Exception as e:
            self.fetch_error = str(e)
            _log.error("do_refresh: exception: %s", e)
        finally:
            self.is_fetching = False

    # --- Rendering ---

    def render_header(self, row):
        """Render the title header. Returns next row."""
        title = "GitHub Actions Watch"
        self.safe_addstr(row, 2, title, curses.A_BOLD | self.color_attr("white"))
        if self.repo:
            self.safe_addstr(row, 2 + len(title) + 2, self.repo, self.color_attr("cyan"))
        row += 1
        return row

    def render_footer(self):
        """Render the status bar at the bottom of the screen."""
        max_y, _ = self.stdscr.getmaxyx()
        footer_row = max_y - 1

        ts = time.strftime("%H:%M:%S")
        if self.is_fetching:
            status = f"Fetching {self.spinner()}  |  "
        elif self.fetch_error:
            status = f"Error: {self.fetch_error}  |  "
        else:
            age = int(time.time()) - self.last_fetch_time if self.last_fetch_time else 0
            status = f"Updated {ts} ({age}s ago)  |  "

        footer = f"{status}[r]efresh  [?]help  [q]uit"

        attr = curses.A_DIM
        if self.fetch_error and not self.is_fetching:
            attr = self.color_attr("red")
        self.safe_addstr(footer_row, 0, footer, attr)

    def render_no_repo(self, row):
        """Render error when repo cannot be detected."""
        self.safe_addstr(row, 2, "No GitHub repo detected.", curses.A_BOLD | self.color_attr("red"))
        row += 2
        self.safe_addstr(row, 2, "Run from inside a GitHub-hosted git repo, or pass --repo owner/name.")
        row += 1
        return row

    def render_table(self, row):
        """Render the workflow runs table. Returns next row."""
        max_y, max_x = self.stdscr.getmaxyx()

        if not self.cached_runs and not self.fetch_error:
            self.safe_addstr(row, 2, "No workflow runs found.", curses.A_DIM)
            return row + 1

        if self.fetch_error and not self.cached_runs:
            self.safe_addstr(row, 2, self.fetch_error, self.color_attr("red"))
            return row + 1

        # Build display rows
        # Columns: Workflow | Branch | Status | Conclusion | Duration | Commit
        headers = ["Workflow", "Branch", "Status", "Conclusion", "Duration", "Commit"]
        col_idx = {h: i for i, h in enumerate(headers)}

        display_rows = []
        for run in self.cached_runs:
            workflow = run.get("workflowName", "")
            branch = run.get("headBranch", "")
            status = run.get("status", "")
            conclusion = run.get("conclusion", "") or ""
            sha = (run.get("headSha") or "")[:7]
            elapsed = format_run_elapsed(run)
            display_status, color_key = map_status_color(status, conclusion)
            display_rows.append({
                "cells": [workflow, branch, display_status, conclusion, elapsed, sha],
                "color_key": color_key,
                "is_active": status in ("in_progress", "queued", "waiting", "requested"),
            })

        # Calculate column widths from content
        widths = [len(h) for h in headers]
        for dr in display_rows:
            for i, cell in enumerate(dr["cells"]):
                widths[i] = max(widths[i], len(cell))
                # Reserve space for spinner on status column
                if i == col_idx["Status"] and dr["is_active"]:
                    widths[i] = max(widths[i], len(cell) + 2)

        # Add padding (1 char each side)
        padded = [w + 2 for w in widths]

        # Shrink to fit terminal width: total = sum(padded) + (ncols+1) separators
        n_cols = len(padded)
        total = sum(padded) + n_cols + 1
        if total > max_x:
            excess = total - max_x
            # Shrink Workflow column first (index 0)
            if padded[0] > 12:
                shrink = min(padded[0] - 12, excess)
                padded[0] -= shrink
                excess -= shrink
            # Then Branch column (index 1)
            if excess > 0 and padded[1] > 8:
                shrink = min(padded[1] - 8, excess)
                padded[1] -= shrink
                excess -= shrink
            # General shrink from widest
            while excess > 0:
                widest_i = max(range(n_cols), key=lambda i: padded[i] if padded[i] > 6 else 0)
                if padded[widest_i] <= 6:
                    break
                padded[widest_i] -= 1
                excess -= 1

        def hline(left, mid, right, fill="-"):
            """Build a horizontal border line."""
            parts = [fill * w for w in padded]
            return left + (mid).join(parts) + right

        # Top border
        top = hline("+", "+", "+")
        self.safe_addstr(row, 0, top)
        row += 1

        # Header row
        if row < max_y - 2:
            x = 0
            self.safe_addstr(row, x, "|")
            x += 1
            for i, h in enumerate(headers):
                w = padded[i]
                pad_l = (w - len(h)) // 2
                pad_r = w - len(h) - pad_l
                self.safe_addstr(row, x, " " * pad_l + h + " " * pad_r, curses.A_BOLD)
                x += w
                self.safe_addstr(row, x, "|")
                x += 1
            row += 1

        # Mid border
        if row < max_y - 2:
            mid = hline("+", "+", "+")
            self.safe_addstr(row, 0, mid)
            row += 1

        # Data rows
        for dr in display_rows:
            if row >= max_y - 2:
                break
            x = 0
            self.safe_addstr(row, x, "|")
            x += 1

            cells = dr["cells"]
            color_key = dr["color_key"]
            is_active = dr["is_active"]

            for i, cell in enumerate(cells):
                w = padded[i]
                max_content = w - 2  # 1 char padding each side
                if max_content < 1:
                    max_content = 1

                # Status column gets spinner if active
                if i == col_idx["Status"] and is_active:
                    display = f"{cell} {self.spinner()}"
                else:
                    display = cell

                # Truncate to fit
                if len(display) > max_content:
                    if max_content >= 3:
                        display = display[:max_content - 2] + ".."
                    else:
                        display = display[:max_content]

                padded_cell = " " + display + " " * (w - 1 - len(display))

                # Color the Status and Conclusion columns
                if i in (col_idx["Status"], col_idx["Conclusion"]):
                    attr = self.color_attr(color_key)
                else:
                    attr = 0

                self.safe_addstr(row, x, padded_cell, attr)
                x += w
                self.safe_addstr(row, x, "|")
                x += 1

            row += 1

        # Bottom border
        if row < max_y - 1:
            bot = hline("+", "+", "+")
            self.safe_addstr(row, 0, bot)
            row += 1

        return row

    def render_help(self, row):
        """Render help overlay. Returns next row."""
        row += 1
        self.safe_addstr(row, 2, "Keyboard Shortcuts", curses.A_BOLD)
        row += 2
        shortcuts = [
            ("r", "Force refresh workflow runs"),
            ("q", "Quit"),
            ("?", "Toggle this help"),
        ]
        for key, desc in shortcuts:
            self.safe_addstr(row, 2, key, curses.A_BOLD)
            self.safe_addstr(row, 4, f"  {desc}")
            row += 1
        row += 2
        self.safe_addstr(row, 2, "Auto-refreshes every 30 seconds.", curses.A_DIM)
        row += 1
        self.safe_addstr(row, 2, "Press any key to dismiss.")
        row += 1
        return row

    def render_screen(self):
        """Full screen render."""
        self.stdscr.erase()
        row = 0

        row = self.render_header(row)
        row += 1  # blank line after header

        if self.show_help:
            self.render_help(row)
        elif not self.repo and self.fetch_error:
            self.render_no_repo(row)
        else:
            self.render_table(row)

        self.render_footer()

        try:
            self.stdscr.refresh()
        except curses.error:
            pass

    # --- Input handling ---

    def handle_input(self, key):
        """Handle a keypress. Returns False to quit, True to continue."""
        if key == -1:
            return True

        try:
            ch = chr(key)
        except (ValueError, OverflowError):
            return True

        # Help screen: any key dismisses
        if self.show_help:
            self.show_help = False
            return True

        if ch in ("q", "Q"):
            return False
        elif ch == "?":
            self.show_help = True
        elif ch in ("r", "R"):
            self.do_refresh()

        return True

    # --- Main loop ---

    def run(self):
        """Main event loop."""
        # Initial fetch
        self.do_refresh()
        self.render_screen()

        last_poll = time.time()

        while True:
            try:
                key = self.stdscr.getch()
            except curses.error:
                key = -1

            if not self.handle_input(key):
                break

            now = time.time()
            if now - last_poll >= POLL_INTERVAL:
                self.do_refresh()
                last_poll = now

            self.render_screen()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Watch GitHub Actions workflow runs in a curses TUI."
    )
    parser.add_argument(
        "--repo", metavar="OWNER/NAME",
        help="GitHub repo slug (e.g. acme/my-app). Auto-detected from git remote if omitted."
    )
    return parser.parse_args()


def main(stdscr):
    locale.setlocale(locale.LC_ALL, "")

    args = parse_args()
    repo = args.repo or None

    app = GHActionsApp(stdscr, repo=repo)
    app.run()


if __name__ == "__main__":
    curses.wrapper(main)
