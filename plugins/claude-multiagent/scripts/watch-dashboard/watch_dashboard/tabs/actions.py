"""Actions tab — DataTable showing GitHub Actions workflow runs."""

from __future__ import annotations

import calendar
import json
import logging
import re
import subprocess
import time

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import DataTable, Static
from textual import work
from rich.text import Text

_log = logging.getLogger("watch-dashboard")

MAX_RUNS = 15

# ---------------------------------------------------------------------------
# Commit color palette — same commit SHA gets same color
# ---------------------------------------------------------------------------

_COMMIT_COLORS = [
    "#89b4fa",  # blue
    "#a6e3a1",  # green
    "#f9e2af",  # yellow
    "#cba6f7",  # mauve
    "#f38ba8",  # red
    "#94e2d5",  # teal
    "#fab387",  # peach
    "#74c7ec",  # sapphire
    "#f2cdcd",  # flamingo
    "#b4befe",  # lavender
]


def _commit_color(sha: str, color_map: dict[str, str]) -> str:
    """Return a consistent color for a commit SHA."""
    if sha not in color_map:
        idx = len(color_map) % len(_COMMIT_COLORS)
        color_map[sha] = _COMMIT_COLORS[idx]
    return color_map[sha]


# ---------------------------------------------------------------------------
# Status styling
# ---------------------------------------------------------------------------


def _map_status_display(status: str, conclusion: str) -> tuple[str, str]:
    """Return (display_text, rich_style) for a workflow run."""
    if status == "completed":
        if conclusion == "success":
            return "success", "bold #a6e3a1"
        elif conclusion in ("failure", "timed_out", "startup_failure"):
            return conclusion or "failure", "bold #f38ba8"
        elif conclusion in ("cancelled", "skipped", "stale"):
            return conclusion or "cancelled", "dim"
        else:
            return conclusion or status, "dim"
    elif status == "in_progress":
        return "in_progress", "bold #f9e2af"
    elif status in ("queued", "waiting", "requested", "pending"):
        return status, "bold #f9e2af"
    else:
        return status, "dim"


# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------


def _parse_gh_time(ts: str) -> int | None:
    """Parse GitHub ISO timestamp to epoch."""
    if not ts:
        return None
    try:
        t = time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
        return int(calendar.timegm(t))
    except (ValueError, TypeError):
        return None


def _fmt_duration(seconds: int | None) -> str:
    """Format seconds as human-readable duration."""
    if seconds is None or seconds < 0:
        return ""
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    elif seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    else:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"


def _format_run_elapsed(run: dict) -> str:
    """Return formatted elapsed/duration string for a workflow run."""
    created_at = _parse_gh_time(run.get("createdAt", ""))
    updated_at = _parse_gh_time(run.get("updatedAt", ""))
    status = run.get("status", "")

    if created_at is None:
        return ""

    if status == "completed" and updated_at:
        return _fmt_duration(updated_at - created_at)
    else:
        elapsed = int(time.time()) - created_at
        return _fmt_duration(max(0, elapsed))


def _format_time_ago(run: dict) -> str:
    """Return how long ago the run started (e.g. '5m ago', '2h ago')."""
    created_at = _parse_gh_time(run.get("createdAt", ""))
    if created_at is None:
        return ""
    ago = int(time.time()) - created_at
    if ago < 0:
        return "just now"
    if ago < 60:
        return f"{ago}s ago"
    if ago < 3600:
        return f"{ago // 60}m ago"
    if ago < 86400:
        h = ago // 3600
        m = (ago % 3600) // 60
        return f"{h}h {m}m ago" if m else f"{h}h ago"
    days = ago // 86400
    return f"{days}d ago"


# ---------------------------------------------------------------------------
# Repo detection
# ---------------------------------------------------------------------------


def _detect_repo(project_dir: str) -> str | None:
    """Detect GitHub repo slug from git remote origin."""
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5,
            cwd=project_dir,
        )
        if result.returncode != 0:
            return None
        remote_url = result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None

    match = re.search(r"github\.com[:/]([^/]+/[^/.]+)(\.git)?$", remote_url)
    if match:
        return match.group(1)
    return None


def _fetch_runs(repo: str) -> list[dict] | None:
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
# ActionsTab widget
# ---------------------------------------------------------------------------


class ActionsTab(Vertical):
    """Content widget for the GitHub Actions tab."""

    def __init__(self, project_dir: str) -> None:
        super().__init__()
        self._project_dir = project_dir
        self._repo: str | None = None
        self._cached_runs: list[dict] = []
        self._urls: list[str] = []
        self._fetch_error = ""
        self._last_fetch_time = 0
        self._commit_color_map: dict[str, str] = {}

    def compose(self) -> ComposeResult:
        yield DataTable(id="actions-table", cursor_type="row", zebra_stripes=True)
        yield Static("", id="actions-status")

    def on_mount(self) -> None:
        table = self.query_one("#actions-table", DataTable)
        table.add_columns("Workflow", "Branch", "Status", "Conclusion", "Started", "Commit")
        self._refresh_data()

    def get_selected_url(self) -> str:
        """Return the URL for the currently selected row, or empty string."""
        table = self.query_one("#actions-table", DataTable)
        if table.row_count == 0:
            return ""
        try:
            row_idx = table.cursor_coordinate.row
            if 0 <= row_idx < len(self._urls):
                return self._urls[row_idx]
        except Exception:
            pass
        return ""

    @work(exclusive=True, thread=True)
    def _refresh_data(self) -> None:
        """Fetch workflow run data in a background thread."""
        if not self._repo:
            self._repo = _detect_repo(self._project_dir)
            _log.debug("_refresh_data: detected repo=%s", self._repo)

        if not self._repo:
            fetch_error = "Could not detect GitHub repo. Check git remote."

            def _apply_no_repo() -> None:
                self._fetch_error = fetch_error
                self._populate_table()

            self.app.call_from_thread(_apply_no_repo)
            return

        runs = _fetch_runs(self._repo)
        fetch_error = ""
        if runs is None:
            fetch_error = "gh run list failed — check gh auth."

        # Build commit color map from fetched data (safe — local vars only)
        color_map: dict[str, str] = {}
        if runs is not None:
            for run in runs:
                sha = (run.get("headSha") or "")[:7]
                if sha and sha not in color_map:
                    _commit_color(sha, color_map)

        fetch_time = int(time.time())

        def _apply() -> None:
            self._fetch_error = fetch_error
            if runs is not None:
                self._cached_runs = runs
                self._commit_color_map = color_map
            self._last_fetch_time = fetch_time
            self._populate_table()

        self.app.call_from_thread(_apply)

    def _populate_table(self) -> None:
        """Populate the DataTable with cached runs."""
        table = self.query_one("#actions-table", DataTable)
        table.clear()
        self._urls = []

        if not self._cached_runs and self._fetch_error:
            self.query_one("#actions-status", Static).update(
                f"[bold red]{self._fetch_error}[/bold red]"
            )
            return

        if not self._cached_runs:
            self.query_one("#actions-status", Static).update("No workflow runs found.")
            return

        for run in self._cached_runs:
            workflow = Text(run.get("workflowName", ""))
            branch = Text(run.get("headBranch", ""), style="#89b4fa")

            status = run.get("status", "")
            conclusion = run.get("conclusion", "") or ""
            display_status, status_style = _map_status_display(status, conclusion)
            status_cell = Text(display_status, style=status_style)
            conclusion_cell = Text(conclusion, style=status_style) if conclusion else Text("")

            duration = Text(_format_time_ago(run), style="dim")

            sha = (run.get("headSha") or "")[:7]
            commit_color = self._commit_color_map.get(sha, "#cdd6f4")
            commit_cell = Text(sha, style=f"bold {commit_color}")

            table.add_row(workflow, branch, status_cell, conclusion_cell, duration, commit_cell)
            self._urls.append(run.get("url", ""))

        # Status line
        ts = time.strftime("%H:%M:%S")
        repo = self._repo or "unknown"
        if self._fetch_error:
            status = f"[bold red]{self._fetch_error}[/bold red] | {repo} | {ts}"
        else:
            status = f"{repo} | Updated {ts}"
        self.query_one("#actions-status", Static).update(status)

    def refresh_data(self) -> None:
        """Public trigger for refresh."""
        self._refresh_data()
