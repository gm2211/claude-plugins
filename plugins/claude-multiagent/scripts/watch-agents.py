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
MIN_COL_WIDTH = 8  # minimum column width when resizing

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

def compute_col_widths(term_width: int, user_widths: dict[int, int] | None = None) -> list[int]:
    """Compute column widths to fill the full terminal width.

    Fixed columns: Agent (15), Ticket(s) (12), Duration (12)
    Flex columns: Summary (55%), Last Action (45%) of remaining space.

    If user_widths is provided, those columns use the user-specified widths
    and the remaining flex space is distributed among non-overridden columns.
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

    # Apply user overrides
    if user_widths:
        for col_idx, w in user_widths.items():
            if 0 <= col_idx < ncols:
                widths[col_idx] = max(w, MIN_COL_WIDTH)

    # Final shrink pass if we exceed target width
    target = term_width - padding
    total = sum(widths) + border_chars
    while total > target:
        # Shrink widest column that isn't user-pinned
        candidates = [i for i in range(ncols) if not (user_widths and i in user_widths)]
        if not candidates:
            candidates = list(range(ncols))
        widest = max(candidates, key=lambda i: widths[i])
        if widths[widest] <= MIN_COL_WIDTH:
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


def render(stdscr, project_dir: str, user_widths: dict[int, int] | None = None,
           drag_sep: int | None = None) -> dict:
    """Render a single frame of the dashboard.

    Returns a dict with layout info for mouse hit-testing:
        header_y: int — the y coordinate of the header row
        sep_xs: list[int] — x coordinates of each interior column separator
        widths: list[int] — the column widths used for this frame
        table_x: int — the x offset where the table starts
    """
    stdscr.erase()
    layout = {"header_y": -1, "sep_xs": [], "widths": [], "table_x": 2}

    max_y, max_x = stdscr.getmaxyx()
    if max_y < 3 or max_x < 20:
        safe_addstr(stdscr, 0, 0, "Terminal too small")
        stdscr.noutrefresh()
        curses.doupdate()
        return layout

    now = time.time()
    row = 0
    table_x = 2  # left margin where the table starts

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
        return layout

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
    widths = compute_col_widths(max_x, user_widths)
    ncols = len(widths)

    # Compute separator x positions (interior separators between columns)
    sep_xs = []
    x = table_x  # start after left margin
    x += 1  # skip the leading |
    for ci in range(ncols - 1):
        x += widths[ci]
        sep_xs.append(x)  # this is the x of the | between col ci and ci+1
        x += 1  # skip the | itself

    layout["widths"] = widths
    layout["sep_xs"] = sep_xs
    layout["table_x"] = table_x

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
    safe_addstr(stdscr, row, table_x, top_border)
    row += 1
    if row >= max_y:
        stdscr.noutrefresh()
        curses.doupdate()
        return layout

    # ── Draw header row ──
    layout["header_y"] = row
    header_x = table_x
    safe_addstr(stdscr, row, header_x, "|", curses.A_BOLD)
    header_x += 1
    for ci in range(ncols):
        w = widths[ci]
        text = truncate(HEADERS[ci], w - 2)
        pad_total = w - len(text)
        pad_left = pad_total // 2
        pad_right = pad_total - pad_left
        cell = " " * pad_left + text + " " * pad_right
        safe_addstr(stdscr, row, header_x, cell, curses.A_BOLD)
        header_x += w
        # Draw separator — highlight if being dragged
        sep_attr = curses.A_BOLD
        if drag_sep is not None and ci < len(sep_xs) and ci == drag_sep:
            sep_attr = curses.A_REVERSE | curses.A_BOLD
        if ci < ncols - 1:
            safe_addstr(stdscr, row, header_x, "|", sep_attr)
        else:
            safe_addstr(stdscr, row, header_x, "|", curses.A_BOLD)
        header_x += 1
    row += 1
    if row >= max_y:
        stdscr.noutrefresh()
        curses.doupdate()
        return layout

    # ── Draw mid border ──
    safe_addstr(stdscr, row, table_x, mid_border)
    row += 1

    # ── Draw data rows ──
    for table_row in table_rows:
        if row >= max_y:
            break
        line_x = table_x
        safe_addstr(stdscr, row, line_x, "|")
        line_x += 1
        for ci in range(ncols):
            w = widths[ci]
            text = truncate(table_row[ci] if ci < len(table_row) else "", w - 2)
            pad = w - len(text) - 1
            cell = " " + text + " " * max(pad, 0)
            safe_addstr(stdscr, row, line_x, cell)
            line_x += w
            # Highlight separator during drag
            sep_attr = 0
            if drag_sep is not None and ci < len(sep_xs) and ci == drag_sep:
                sep_attr = curses.A_REVERSE
            safe_addstr(stdscr, row, line_x, "|", sep_attr)
            line_x += 1
        row += 1

    # ── Draw bottom border ──
    if row < max_y:
        safe_addstr(stdscr, row, table_x, bot_border)
        row += 1

    # ── Updated timestamp at bottom ──
    if row + 1 < max_y:
        row += 1
        hint = "  Drag column borders to resize"
        updated = f"  Updated {time.strftime('%H:%M:%S')}"
        safe_addstr(stdscr, row, 0, updated, curses.A_DIM)
        hint_pos = max(0, max_x - len(hint) - 2)
        safe_addstr(stdscr, row, hint_pos, hint, curses.A_DIM)

    stdscr.noutrefresh()
    curses.doupdate()
    return layout


# ── Main loop ────────────────────────────────────────────────────────────

def find_separator(x: int, sep_xs: list[int], tolerance: int = 1) -> int | None:
    """Find the separator index closest to x within tolerance.

    Returns the separator index (0-based, between col i and col i+1) or None.
    """
    for i, sx in enumerate(sep_xs):
        if abs(x - sx) <= tolerance:
            return i
    return None


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

    # Enable mouse events for column resizing
    curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
    # Enable mouse-movement reporting so we get drag events
    # (xterm-style: \033[?1003h enables all-motion tracking)
    sys.stdout.write("\033[?1003h")
    sys.stdout.flush()

    # Persistent user column widths — survives across refresh cycles
    user_widths: dict[int, int] = {}

    # Drag state
    drag_sep: int | None = None  # which separator index is being dragged
    drag_start_x: int = 0  # mouse x when drag started
    drag_start_widths: list[int] = []  # snapshot of widths when drag started

    # Layout from last render
    layout: dict = {"header_y": -1, "sep_xs": [], "widths": [], "table_x": 2}

    while True:
        layout = render(stdscr, project_dir, user_widths, drag_sep)
        try:
            key = stdscr.getch()
        except curses.error:
            continue

        if key == ord("q") or key == ord("Q"):
            break
        elif key == curses.KEY_RESIZE:
            curses.update_lines_cols()
            continue
        elif key == curses.KEY_MOUSE:
            try:
                _, mx, my, _, bstate = curses.getmouse()
            except curses.error:
                continue

            sep_xs = layout.get("sep_xs", [])
            header_y = layout.get("header_y", -1)
            cur_widths = layout.get("widths", [])

            if bstate & curses.BUTTON1_PRESSED:
                # Start drag if clicking near a separator
                sep_idx = find_separator(mx, sep_xs)
                if sep_idx is not None:
                    drag_sep = sep_idx
                    drag_start_x = mx
                    drag_start_widths = list(cur_widths)

            elif bstate & curses.BUTTON1_RELEASED:
                # End drag
                if drag_sep is not None:
                    drag_sep = None

            elif drag_sep is not None:
                # Mouse motion during drag — resize columns
                dx = mx - drag_start_x
                if dx != 0 and drag_start_widths:
                    left_col = drag_sep
                    right_col = drag_sep + 1
                    if left_col < len(drag_start_widths) and right_col < len(drag_start_widths):
                        new_left = drag_start_widths[left_col] + dx
                        new_right = drag_start_widths[right_col] - dx
                        # Enforce minimum widths
                        if new_left >= MIN_COL_WIDTH and new_right >= MIN_COL_WIDTH:
                            user_widths[left_col] = new_left
                            user_widths[right_col] = new_right

        elif key == ord("r") or key == ord("R"):
            # Reset column widths to auto
            user_widths.clear()
        # Any other key or timeout (-1): just re-render

    # Disable mouse-motion reporting on exit
    sys.stdout.write("\033[?1003l")
    sys.stdout.flush()


if __name__ == "__main__":
    curses.wrapper(main)
