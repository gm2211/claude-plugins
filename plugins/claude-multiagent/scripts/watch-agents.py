#!/usr/bin/env python3
"""Agent status dashboard — curses TUI with card-style layout.

Reads per-agent status files from .agent-status.d/ and renders a
fat-row card layout with Unicode box-drawing characters.

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
STALE_THRESHOLD_SECONDS = 180  # >180s since update → stale (red)

CARD_LEFT_MARGIN = 2
CARD_MIN_WIDTH = 40
CARD_HEIGHT = 6  # top border + 3 content rows + bottom border + blank gap

# Color pair IDs
COLOR_TITLE = 1
COLOR_STALE = 2
CARD_COLOR_START = 3

# Foreground colors cycled across agent cards
CARD_FG_COLORS = [
    curses.COLOR_CYAN,
    curses.COLOR_GREEN,
    curses.COLOR_YELLOW,
    curses.COLOR_MAGENTA,
    curses.COLOR_BLUE,
    curses.COLOR_WHITE,
]


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


def format_last_action(raw: str, now: float) -> tuple[str, str]:
    """Parse 'description|timestamp' into (description, ago_string).

    Returns (description, ago) where ago may be "" if not parseable.
    """
    if "|" not in raw:
        return raw, ""
    desc, _, ts_str = raw.rpartition("|")
    try:
        ts = int(ts_str)
        ago = elapsed_str(int(now - ts))
        return desc, ago
    except ValueError:
        return raw, ""


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


# ── Color initialization ──────────────────────────────────────────────────

def init_colors() -> bool:
    """Initialize color pairs. Returns True if colors are available."""
    if not curses.has_colors():
        return False
    curses.start_color()
    curses.use_default_colors()

    curses.init_pair(COLOR_TITLE, curses.COLOR_WHITE, -1)
    curses.init_pair(COLOR_STALE, curses.COLOR_RED, -1)

    for i, fg in enumerate(CARD_FG_COLORS):
        curses.init_pair(CARD_COLOR_START + i, fg, -1)

    return True


def card_attr(agent_idx: int, bold: bool = False) -> int:
    """Return the curses attribute for a card's color."""
    pair_id = CARD_COLOR_START + (agent_idx % len(CARD_FG_COLORS))
    attr = curses.color_pair(pair_id)
    if bold:
        attr |= curses.A_BOLD
    return attr


# ── Rendering ────────────────────────────────────────────────────────────

def safe_addstr(win, y: int, x: int, text: str, attr: int = 0) -> None:
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


def truncate(text: str, max_len: int) -> str:
    """Truncate text with ellipsis if it exceeds max_len."""
    if len(text) <= max_len:
        return text
    if max_len >= 3:
        return text[: max_len - 2] + ".."
    return text[:max_len]


def pad_right(text: str, width: int) -> str:
    """Pad text with spaces on the right to reach exactly `width` chars."""
    if len(text) >= width:
        return text[:width]
    return text + " " * (width - len(text))


def render_card(stdscr, row: int, agent: dict, agent_idx: int,
                card_width: int, now: float, selected: bool,
                has_colors: bool) -> int:
    """Render a single agent card at the given row.

    Returns the row index after the card (including one blank gap line).
    Card structure (6 rows total including gap):
        ┌─ name ────────── ticket ─┐
        │ Status: <summary>        │
        │ Last:   <desc>  (<ago>)  │
        │ Updated: Xs ago          │
        └──────────────────────────┘
        (blank)
    """
    max_y, _ = stdscr.getmaxyx()
    x = CARD_LEFT_MARGIN

    # inner width = card_width - 2 (left + right borders)
    inner = card_width - 2

    # Color attributes
    if has_colors:
        border_attr = card_attr(agent_idx, bold=True)
        content_attr = curses.A_NORMAL
    else:
        border_attr = curses.A_BOLD
        content_attr = curses.A_NORMAL

    if selected:
        border_attr |= curses.A_REVERSE

    # ── Parse fields ──
    agent_name = agent["agent"]
    ticket_id = agent["ticket"]
    summary = agent["summary"]

    try:
        start_ts = int(agent["start_ts"])
        updated_ago_secs = int(now - start_ts)
    except (ValueError, TypeError):
        updated_ago_secs = 0

    last_desc, last_ago = format_last_action(agent["last_action"], now)

    stale = updated_ago_secs > STALE_THRESHOLD_SECONDS
    if has_colors and stale:
        updated_attr = curses.color_pair(COLOR_STALE) | curses.A_BOLD
    elif stale:
        updated_attr = curses.A_BOLD
    else:
        updated_attr = curses.A_DIM

    # ── Top border: ┌─ <name> ─── <ticket> ─┐ ──
    name_seg = f" {agent_name} "
    ticket_seg = f" {ticket_id} "
    # "┌─" + name_seg + dashes + ticket_seg + "─┐"
    # total fixed chars: 2 + len(name_seg) + len(ticket_seg) + 2 = 4 + lens
    fixed_chars = 4 + len(name_seg) + len(ticket_seg)
    dash_fill = max(inner - fixed_chars, 1)
    top_border = "┌─" + name_seg + "─" * dash_fill + ticket_seg + "─┐"
    # Adjust if off by one due to rounding
    if len(top_border) > card_width:
        top_border = top_border[: card_width - 1] + "┐"
    elif len(top_border) < card_width:
        # Insert one more dash
        top_border = "┌─" + name_seg + "─" * (dash_fill + 1) + ticket_seg + "─┐"
        if len(top_border) > card_width:
            top_border = top_border[: card_width - 1] + "┐"

    if row < max_y:
        safe_addstr(stdscr, row, x, top_border[:card_width], border_attr)
    row += 1

    # ── Status row: │ Status: <summary>  │ ──
    LABEL_S = "Status: "
    val_avail = inner - 1 - len(LABEL_S)  # leading space takes 1 char
    status_val = truncate(summary, max(val_avail, 0))
    status_content = pad_right(" " + LABEL_S + status_val, inner)
    if row < max_y:
        safe_addstr(stdscr, row, x, "│", border_attr)
        safe_addstr(stdscr, row, x + 1, status_content[:inner], content_attr)
        safe_addstr(stdscr, row, x + 1 + inner, "│", border_attr)
    row += 1

    # ── Last action row: │ Last:   <desc>  (<ago>)  │ ──
    LABEL_L = "Last:   "
    ago_suffix = f" ({last_ago})" if last_ago else ""
    val_avail_l = inner - 1 - len(LABEL_L)
    desc_max = max(val_avail_l - len(ago_suffix), 4)
    last_desc_t = truncate(last_desc, desc_max)
    last_content = pad_right(" " + LABEL_L + last_desc_t + ago_suffix, inner)
    if row < max_y:
        safe_addstr(stdscr, row, x, "│", border_attr)
        safe_addstr(stdscr, row, x + 1, last_content[:inner], content_attr)
        safe_addstr(stdscr, row, x + 1 + inner, "│", border_attr)
    row += 1

    # ── Updated row: │ Updated: Xs ago  │ ──
    LABEL_U = "Updated: "
    updated_val = elapsed_str(updated_ago_secs) + " ago"
    updated_content = pad_right(" " + LABEL_U + updated_val, inner)
    if row < max_y:
        safe_addstr(stdscr, row, x, "│", border_attr)
        safe_addstr(stdscr, row, x + 1, updated_content[:inner], updated_attr)
        safe_addstr(stdscr, row, x + 1 + inner, "│", border_attr)
    row += 1

    # ── Bottom border ──
    bot_border = "└" + "─" * (card_width - 2) + "┘"
    if row < max_y:
        safe_addstr(stdscr, row, x, bot_border[:card_width], border_attr)
    row += 1

    # Blank gap between cards
    row += 1

    return row


def render_detail_view(stdscr, agent: dict, now: float, has_colors: bool) -> None:
    """Render a full-screen detail view for the selected agent."""
    stdscr.erase()
    max_y, max_x = stdscr.getmaxyx()

    safe_addstr(stdscr, 0, 0, f"  Agent Detail: {agent['agent']}", curses.A_BOLD)
    safe_addstr(stdscr, 1, 0, "  " + "─" * max(max_x - 4, 1))

    row = 3

    try:
        start_ts = int(agent["start_ts"])
        running = elapsed_str(int(now - start_ts))
        updated = elapsed_str(int(now - start_ts)) + " ago"
    except (ValueError, TypeError):
        running = agent.get("start_ts", "?")
        updated = "?"

    last_desc, last_ago = format_last_action(agent["last_action"], now)
    last_full = last_desc + (f" ({last_ago} ago)" if last_ago else "")

    fields = [
        ("Agent", agent["agent"]),
        ("Ticket", agent["ticket"]),
        ("Running", running),
        ("Updated", updated),
        ("Summary", agent["summary"]),
        ("Last Action", last_full),
    ]

    for label, value in fields:
        if row >= max_y - 2:
            break
        label_str = f"  {label:<14}: "
        safe_addstr(stdscr, row, 0, label_str, curses.A_BOLD)
        safe_addstr(stdscr, row, len(label_str),
                    value[: max(max_x - len(label_str) - 1, 0)])
        row += 1

    if row + 1 < max_y:
        safe_addstr(stdscr, row + 1, 2, "Press any key to return", curses.A_DIM)

    stdscr.noutrefresh()
    curses.doupdate()


def render(stdscr, project_dir: str, scroll_offset: int, selected_idx: int,
           has_colors: bool) -> tuple[int, list[dict]]:
    """Render a single frame of the card dashboard.

    Returns (total_agent_count, agents_list).
    """
    stdscr.erase()
    max_y, max_x = stdscr.getmaxyx()

    if max_y < 4 or max_x < 20:
        safe_addstr(stdscr, 0, 0, "Terminal too small")
        stdscr.noutrefresh()
        curses.doupdate()
        return 0, []

    now = time.time()

    # ── Title bar ──
    title = "Agent Status Dashboard"
    timestamp = time.strftime("%H:%M:%S")
    title_attr = (curses.color_pair(COLOR_TITLE) | curses.A_BOLD) if has_colors else curses.A_BOLD
    ts_pos = max(0, max_x - len(timestamp) - 2)
    safe_addstr(stdscr, 0, 0, f"  {title}", title_attr)
    safe_addstr(stdscr, 0, ts_pos, timestamp, curses.A_DIM)

    # ── Collect agents ──
    agents = collect_agents(project_dir)

    if not agents:
        safe_addstr(stdscr, 2, 2, "No active agents.")
        safe_addstr(stdscr, max_y - 1, 2, "q=quit  r=refresh", curses.A_DIM)
        stdscr.noutrefresh()
        curses.doupdate()
        return 0, []

    # Card fills terminal width minus margins
    card_width = max(max_x - CARD_LEFT_MARGIN - 2, CARD_MIN_WIDTH)

    # Content starts at row 2 (after title + blank line)
    content_start = 2
    current_draw_row = content_start

    for i, agent in enumerate(agents):
        # Compute where this card would draw on screen (accounting for scroll)
        draw_row = current_draw_row - scroll_offset

        # Skip if fully above viewport
        if draw_row + CARD_HEIGHT <= 0:
            current_draw_row += CARD_HEIGHT
            continue

        # Stop drawing once fully below viewport (leave room for status bar)
        if draw_row >= max_y - 1:
            break

        selected = (i == selected_idx)
        next_draw_row = render_card(
            stdscr, draw_row, agent, i, card_width, now, selected, has_colors
        )
        current_draw_row += CARD_HEIGHT

    # ── Status bar ──
    hint = "j/k=navigate  enter=detail  r=refresh  q=quit"
    count_str = f"  {len(agents)} agent{'s' if len(agents) != 1 else ''}"
    hint_pos = max(0, max_x - len(hint) - 2)
    safe_addstr(stdscr, max_y - 1, 0, count_str, curses.A_DIM)
    safe_addstr(stdscr, max_y - 1, hint_pos, hint, curses.A_DIM)

    stdscr.noutrefresh()
    curses.doupdate()
    return len(agents), agents


# ── Main loop ────────────────────────────────────────────────────────────

def main(stdscr) -> None:
    if len(sys.argv) > 1:
        project_dir = sys.argv[1]
    else:
        project_dir = os.getcwd()

    curses.curs_set(0)
    has_colors = init_colors()
    curses.halfdelay(REFRESH_HALFDELAY_TENTHS)

    scroll_offset = 0   # how many rows the view is scrolled down
    selected_idx = 0    # which agent card is highlighted
    in_detail = False
    detail_agent: dict | None = None

    while True:
        now = time.time()

        if in_detail and detail_agent is not None:
            render_detail_view(stdscr, detail_agent, now, has_colors)
            try:
                key = stdscr.getch()
            except curses.error:
                continue

            if key == -1:
                continue  # timeout — keep refreshing detail
            elif key == curses.KEY_RESIZE:
                curses.update_lines_cols()
            else:
                in_detail = False
                detail_agent = None

        else:
            total, agents = render(
                stdscr, project_dir, scroll_offset, selected_idx, has_colors
            )

            try:
                key = stdscr.getch()
            except curses.error:
                continue

            if key == ord("q") or key == ord("Q"):
                break

            elif key == curses.KEY_RESIZE:
                curses.update_lines_cols()

            elif key in (ord("j"), curses.KEY_DOWN):
                if total > 0:
                    selected_idx = min(selected_idx + 1, total - 1)
                    # Scroll to keep selected card visible
                    max_y, _ = stdscr.getmaxyx()
                    visible_cards = max(1, (max_y - 3) // CARD_HEIGHT)
                    if selected_idx >= scroll_offset + visible_cards:
                        scroll_offset = selected_idx - visible_cards + 1

            elif key in (ord("k"), curses.KEY_UP):
                if total > 0:
                    selected_idx = max(selected_idx - 1, 0)
                    if selected_idx < scroll_offset:
                        scroll_offset = selected_idx

            elif key in (ord("\n"), curses.KEY_ENTER, 10, 13):
                if agents and 0 <= selected_idx < len(agents):
                    in_detail = True
                    detail_agent = agents[selected_idx]

            elif key in (ord("r"), ord("R")):
                scroll_offset = 0
                selected_idx = 0
            # timeout (-1) or unrecognized key: re-render on next loop


if __name__ == "__main__":
    curses.wrapper(main)
