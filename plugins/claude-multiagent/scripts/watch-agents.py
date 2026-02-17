#!/usr/bin/env python3
"""Agent status dashboard — curses TUI.

Reads per-agent status files from .agent-status.d/ and renders a
full-width ASCII table with auto-refresh.  Replaces watch-agents.sh.

Status file format (one TSV line per file):
    <agent>\t<ticket>\t<unix-ts>\t<summary>\t<last-action>|<unix-ts>
"""

import curses
import os
import sys
import time

# ── Configuration ────────────────────────────────────────────────────────

STATUS_DIR = ".agent-status.d"
REFRESH_HALFDELAY_TENTHS = 20  # curses half-delay: 2 seconds

FIXED_COLS = [
    ("Agent", 15),
    ("Ticket(s)", 12),
    ("Duration", 12),
]
FLEX_COLS = [
    ("Summary", 0.55),
    ("Last Action", 0.45),
]
HEADERS = [name for name, _ in FIXED_COLS] + [name for name, _ in FLEX_COLS]


# ── Helpers ──────────────────────────────────────────────────────────────

def elapsed_str(seconds: int) -> str:
    """Format an elapsed duration into a human-readable string."""
    if seconds < 0:
        seconds = 0
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    hours = seconds // 3600
    mins = (seconds % 3600) // 60
    return f"{hours}h {mins}m"


def format_last_action(raw: str, now: float) -> str:
    """Parse 'description|timestamp' into 'description (Xm ago)'."""
    if "|" not in raw:
        return raw
    desc, _, ts_str = raw.rpartition("|")
    try:
        ts = int(ts_str)
        ago = elapsed_str(int(now - ts))
        return f"{desc} ({ago} ago)"
    except ValueError:
        return raw


def common_prefix(strings: list[str]) -> str:
    """Return the longest common prefix of a list of strings."""
    if not strings:
        return ""
    prefix = strings[0]
    for s in strings[1:]:
        while prefix and not s.startswith(prefix):
            prefix = prefix[:-1]
        if not prefix:
            break
    return prefix


def strip_ticket_prefix(tickets: list[str]) -> tuple[list[str], str]:
    """Strip the shared prefix from ticket IDs.

    Returns (stripped_tickets, prefix_used).
    """
    atoms: list[str] = []
    for t in tickets:
        for part in t.split(","):
            part = part.strip()
            if part:
                atoms.append(part)

    if len(atoms) <= 1:
        return tickets, ""

    prefix = common_prefix(atoms)
    # Only strip on word boundary (ending with - or /)
    if prefix and not prefix.endswith("-") and not prefix.endswith("/"):
        idx_dash = prefix.rfind("-")
        idx_slash = prefix.rfind("/")
        boundary = max(idx_dash, idx_slash)
        if boundary >= 0:
            prefix = prefix[: boundary + 1]
        else:
            prefix = ""

    if not prefix:
        return tickets, ""

    stripped = []
    for t in tickets:
        parts = [p.strip().removeprefix(prefix) for p in t.split(",")]
        stripped.append(", ".join(parts))
    return stripped, prefix


def read_status_dir(directory: str, seen: set[str]) -> list[dict]:
    """Read agent status files from a directory.

    Each file contains one TSV line:
        agent_name\\tticket\\tstart_ts\\tsummary\\tlast_action|ts
    """
    agents: list[dict] = []
    if not os.path.isdir(directory):
        return agents
    try:
        entries = os.listdir(directory)
    except OSError:
        return agents

    for filename in sorted(entries):
        if filename in seen:
            continue
        filepath = os.path.join(directory, filename)
        if not os.path.isfile(filepath):
            continue
        try:
            with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                line = f.readline().strip()
        except OSError:
            continue
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            # Pad with empty strings
            parts.extend([""] * (5 - len(parts)))
        agents.append(
            {
                "agent": parts[0],
                "ticket": parts[1],
                "start_ts": parts[2],
                "summary": parts[3],
                "last_action": parts[4],
            }
        )
        seen.add(filename)
    return agents


def collect_agents(project_dir: str) -> list[dict]:
    """Collect all active agent data from status directories."""
    seen: set[str] = set()
    agents: list[dict] = []

    # Primary: main .agent-status.d/
    main_dir = os.path.join(project_dir, STATUS_DIR)
    agents.extend(read_status_dir(main_dir, seen))

    # Fallback: worktree .agent-status.d/ directories
    worktrees_dir = os.path.join(project_dir, ".worktrees")
    if os.path.isdir(worktrees_dir):
        try:
            for wt in sorted(os.listdir(worktrees_dir)):
                wt_path = os.path.join(worktrees_dir, wt)
                if not os.path.isdir(wt_path):
                    continue
                wt_status = os.path.join(wt_path, STATUS_DIR)
                agents.extend(read_status_dir(wt_status, seen))
                # Nested worktrees
                try:
                    for nested in sorted(os.listdir(wt_path)):
                        nested_path = os.path.join(wt_path, nested)
                        if os.path.isdir(nested_path):
                            nested_status = os.path.join(nested_path, STATUS_DIR)
                            agents.extend(read_status_dir(nested_status, seen))
                except OSError:
                    pass
        except OSError:
            pass

    return agents


# ── Column width calculation ─────────────────────────────────────────────

def compute_col_widths(term_width: int) -> list[int]:
    """Compute column widths to fill the full terminal width.

    Fixed columns: Agent (15), Ticket(s) (12), Duration (12)
    Flex columns: Summary (55%), Last Action (45%) of remaining space.
    """
    ncols = len(HEADERS)
    border_chars = ncols + 1  # one | per column boundary plus edges
    padding = 4  # 2 chars left/right margin
    available = term_width - padding - border_chars

    fixed_widths = [w for _, w in FIXED_COLS]
    fixed_total = sum(fixed_widths)

    flex_space = max(available - fixed_total, 10)
    flex_widths = [max(int(flex_space * frac), 5) for _, frac in FLEX_COLS]
    # Ensure sum matches flex_space (rounding adjustment)
    flex_widths[-1] = flex_space - sum(flex_widths[:-1])
    if flex_widths[-1] < 5:
        flex_widths[-1] = 5

    widths = fixed_widths + flex_widths

    # Final shrink pass if we exceed target width
    target = term_width - padding
    total = sum(widths) + border_chars
    while total > target:
        # Shrink widest column
        widest = max(range(ncols), key=lambda i: widths[i])
        if widths[widest] <= 5:
            break
        widths[widest] -= 1
        total -= 1

    return widths


# ── Rendering ────────────────────────────────────────────────────────────

def truncate(text: str, max_len: int) -> str:
    """Truncate text with ellipsis if it exceeds max_len."""
    if len(text) <= max_len:
        return text
    if max_len >= 3:
        return text[: max_len - 2] + ".."
    return text[:max_len]


def safe_addstr(win, y: int, x: int, text: str, attr: int = 0):
    """Write a string to a curses window, clipping to window bounds."""
    max_y, max_x = win.getmaxyx()
    if y < 0 or y >= max_y or x >= max_x:
        return
    avail = max_x - x
    if avail <= 0:
        return
    clipped = text[:avail]
    try:
        win.addstr(y, x, clipped, attr)
    except curses.error:
        # Writing to the very last cell can raise an error; ignore.
        pass


def render(stdscr, project_dir: str) -> None:
    """Render a single frame of the dashboard."""
    stdscr.erase()

    max_y, max_x = stdscr.getmaxyx()
    if max_y < 3 or max_x < 20:
        safe_addstr(stdscr, 0, 0, "Terminal too small")
        stdscr.noutrefresh()
        curses.doupdate()
        return

    now = time.time()
    row = 0

    # ── Title ──
    title = "Agent Status"
    timestamp = time.strftime("%H:%M:%S")
    title_line = f"  {title}"
    ts_pos = max(0, max_x - len(timestamp) - 2)
    safe_addstr(stdscr, row, 0, title_line, curses.A_BOLD)
    safe_addstr(stdscr, row, ts_pos, timestamp, curses.A_DIM)
    row += 2

    # ── Collect data ──
    agents = collect_agents(project_dir)

    if not agents:
        safe_addstr(stdscr, row, 2, "No active agents.")
        stdscr.noutrefresh()
        curses.doupdate()
        return

    # ── Prepare rows ──
    tickets_raw = [a["ticket"] for a in agents]
    tickets_stripped, _prefix = strip_ticket_prefix(tickets_raw)

    table_rows: list[list[str]] = []
    for i, agent in enumerate(agents):
        # Duration
        try:
            start = int(agent["start_ts"])
            duration = elapsed_str(int(now - start))
        except (ValueError, TypeError):
            duration = agent["start_ts"]

        # Last action
        last_action = format_last_action(agent["last_action"], now)

        table_rows.append(
            [
                agent["agent"],
                tickets_stripped[i],
                duration,
                agent["summary"],
                last_action,
            ]
        )

    # ── Column widths ──
    widths = compute_col_widths(max_x)
    ncols = len(widths)

    def hline(left: str, mid: str, right: str, fill: str) -> str:
        parts = [left]
        for ci in range(ncols):
            parts.append(fill * widths[ci])
            parts.append(mid if ci < ncols - 1 else right)
        return "".join(parts)

    top_border = hline("+", "+", "+", "-")
    mid_border = hline("+", "+", "+", "-")
    bot_border = hline("+", "+", "+", "-")

    # ── Draw top border ──
    safe_addstr(stdscr, row, 2, top_border)
    row += 1
    if row >= max_y:
        stdscr.noutrefresh()
        curses.doupdate()
        return

    # ── Draw header row ──
    header_line = "|"
    for ci in range(ncols):
        w = widths[ci]
        text = truncate(HEADERS[ci], w - 2)
        pad_total = w - len(text)
        pad_left = pad_total // 2
        pad_right = pad_total - pad_left
        header_line += " " * pad_left + text + " " * pad_right + "|"
    safe_addstr(stdscr, row, 2, header_line, curses.A_BOLD)
    row += 1
    if row >= max_y:
        stdscr.noutrefresh()
        curses.doupdate()
        return

    # ── Draw mid border ──
    safe_addstr(stdscr, row, 2, mid_border)
    row += 1

    # ── Draw data rows ──
    for table_row in table_rows:
        if row >= max_y:
            break
        line = "|"
        for ci in range(ncols):
            w = widths[ci]
            text = truncate(table_row[ci] if ci < len(table_row) else "", w - 2)
            pad = w - len(text) - 1
            line += " " + text + " " * max(pad, 0) + "|"
        safe_addstr(stdscr, row, 2, line)
        row += 1

    # ── Draw bottom border ──
    if row < max_y:
        safe_addstr(stdscr, row, 2, bot_border)
        row += 1

    # ── Updated timestamp at bottom ──
    if row + 1 < max_y:
        row += 1
        updated = f"  Updated {time.strftime('%H:%M:%S')}"
        safe_addstr(stdscr, row, 0, updated, curses.A_DIM)

    stdscr.noutrefresh()
    curses.doupdate()


# ── Main loop ────────────────────────────────────────────────────────────

def main(stdscr) -> None:
    # Determine project directory: prefer explicit arg, else walk up to
    # find .agent-status.d or .git, else use cwd.
    if len(sys.argv) > 1:
        project_dir = sys.argv[1]
    else:
        project_dir = os.getcwd()

    curses.curs_set(0)  # Hide cursor
    curses.use_default_colors()  # Transparent background
    curses.halfdelay(REFRESH_HALFDELAY_TENTHS)

    while True:
        render(stdscr, project_dir)
        try:
            key = stdscr.getch()
        except curses.error:
            continue

        if key == ord("q") or key == ord("Q"):
            break
        elif key == curses.KEY_RESIZE:
            curses.update_lines_cols()
            continue
        # Any other key or timeout (-1): just re-render


if __name__ == "__main__":
    curses.wrapper(main)
