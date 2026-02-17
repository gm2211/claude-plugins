#!/usr/bin/env python3
"""Interactive TUI for browsing beads tickets using curses."""

import curses
import os
import re
import subprocess
import sys
import time
import threading

BD = os.path.expanduser("~/.local/bin/bd")

# Status symbol -> curses color pair index mapping
STATUS_COLORS = {
    "\u25cb": 1,  # open (green)
    "\u25d0": 2,  # in_progress (yellow)
    "\u25cf": 3,  # blocked (red)
    "\u2713": 4,  # closed (gray)
    "\u2744": 5,  # deferred (cyan)
}


class Ticket:
    __slots__ = ("full_id", "short_id", "status_char", "priority", "title", "raw_line")

    def __init__(self, full_id, short_id, status_char, priority, title, raw_line):
        self.full_id = full_id
        self.short_id = short_id
        self.status_char = status_char
        self.priority = priority
        self.title = title
        self.raw_line = raw_line


def run_bd(*args):
    """Run a bd command and return stdout, or None on failure."""
    try:
        result = subprocess.run(
            [BD] + list(args),
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return result.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    return None


def parse_tickets(raw_output):
    """Parse bd list --pretty output into a list of Ticket objects and a summary string."""
    if not raw_output or raw_output.strip() == "No issues found.":
        return [], ""

    lines = raw_output.strip().split("\n")

    # Detect common prefix from first ticket ID
    prefix = ""
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and not line.startswith("Total:") and not line.startswith("Status:") and not re.match(r"^-+$", line):
            first_id = parts[1]
            m = re.match(r"^(.+-)[a-z0-9]+$", first_id)
            if m:
                prefix = m.group(1)
            break

    tickets = []
    summary = ""

    for line in lines:
        stripped = line.strip()
        if not stripped or re.match(r"^-+$", stripped):
            continue
        if stripped.startswith("Total:"):
            summary = stripped
            continue
        if stripped.startswith("Status:"):
            continue

        # Parse: <status_symbol> <full-id> <priority_symbol> <priority> <title...>
        status_char = stripped[0] if stripped else ""
        after_sym = stripped[2:] if len(stripped) > 2 else ""
        parts = after_sym.split()
        if not parts:
            continue

        full_id = parts[0]
        rest = after_sym[len(full_id):].strip()

        short_id = full_id
        if prefix and full_id.startswith(prefix):
            short_id = full_id[len(prefix):]

        # Extract priority if present (e.g. "● P2 Title...")
        priority = ""
        title = rest
        prio_match = re.match(r"^[^\s]+\s+(P\d)\s+(.+)$", rest)
        if prio_match:
            priority = prio_match.group(1)
            title = prio_match.group(2)

        tickets.append(Ticket(full_id, short_id, status_char, priority, title, stripped))

    return tickets, summary


def get_detail(ticket_id):
    """Fetch and return bd show output for a ticket."""
    output = run_bd("show", ticket_id)
    if output:
        return output.rstrip()
    return f"(Failed to load details for {ticket_id})"


def color_for_status(status_char):
    """Return the curses color pair number for a status character."""
    return STATUS_COLORS.get(status_char, 0)


class BeadsTUI:
    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.mode = "list"  # list | detail
        self.cursor = 0
        self.scroll = 0
        self.tickets = []
        self.summary = ""
        self.detail_lines = []
        self.detail_scroll = 0
        self.error_msg = ""
        self.last_refresh = 0.0
        self._refresh_lock = threading.Lock()
        self._stop_event = threading.Event()

    def setup_colors(self):
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)    # open
        curses.init_pair(2, curses.COLOR_YELLOW, -1)    # in_progress
        curses.init_pair(3, curses.COLOR_RED, -1)       # blocked
        curses.init_pair(4, 8, -1)                      # closed (gray = color 8)
        curses.init_pair(5, curses.COLOR_CYAN, -1)      # deferred
        curses.init_pair(6, -1, -1)                     # default (for DIM text)

    def load_tickets(self):
        """Load tickets from bd. Thread-safe."""
        if not os.path.isfile(BD):
            self.tickets = []
            self.summary = ""
            self.error_msg = "bd command not found. Install beads to use this panel."
            return

        if not os.path.isdir(".beads"):
            self.tickets = []
            self.summary = ""
            self.error_msg = "No beads initialized in this repo. Run 'bd init' to get started."
            return

        raw = run_bd("list", "--pretty")
        if raw is None:
            self.error_msg = "(bd list failed or returned empty)"
            return

        with self._refresh_lock:
            self.tickets, self.summary = parse_tickets(raw)
            self.error_msg = ""
            # Clamp cursor
            count = len(self.tickets)
            if count == 0:
                self.cursor = 0
            elif self.cursor >= count:
                self.cursor = count - 1
            self.last_refresh = time.time()

    def bg_refresh_loop(self):
        """Background thread that refreshes tickets every 5 seconds."""
        while not self._stop_event.wait(5.0):
            if self.mode == "list":
                self.load_tickets()

    def header_lines_count(self):
        return 3  # title + separator + blank

    def footer_lines_count(self):
        return 2  # blank + keybindings

    def visible_rows(self):
        h, _ = self.stdscr.getmaxyx()
        return max(1, h - self.header_lines_count() - self.footer_lines_count())

    def adjust_scroll(self):
        vis = self.visible_rows()
        if self.cursor < self.scroll:
            self.scroll = self.cursor
        elif self.cursor >= self.scroll + vis:
            self.scroll = self.cursor - vis + 1

    def render_list(self):
        stdscr = self.stdscr
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        if h < 3 or w < 10:
            return

        # Header line 1: title + counts + timestamp
        row = 0
        stdscr.addstr(row, 1, "Beads", curses.A_BOLD)
        col = 7

        # Parse summary for counts
        if self.summary:
            m = re.search(r"\((.+)\)", self.summary)
            if m:
                counts_text = m.group(1)
                stdscr.addstr(row, col, "  " + counts_text, curses.A_DIM)
                col += len(counts_text) + 2

        # Timestamp right-aligned
        ts = time.strftime("%H:%M:%S")
        ts_col = w - len(ts) - 2
        if ts_col > col:
            stdscr.addstr(row, ts_col, ts, curses.A_DIM)

        # Header line 2: separator
        row = 1
        sep_len = min(w - 2, 60)
        stdscr.addstr(row, 1, "\u2500" * sep_len, curses.A_DIM)

        # Ticket list
        row = 2
        vis = self.visible_rows()
        count = len(self.tickets)

        if count == 0:
            # Show error or placeholder
            msg = self.error_msg or "No open tickets."
            stdscr.addstr(row, 2, msg, curses.A_DIM)
        else:
            self.adjust_scroll()
            end = min(self.scroll + vis, count)
            for i in range(self.scroll, end):
                t = self.tickets[i]
                is_selected = (i == self.cursor)
                y = row + (i - self.scroll)
                if y >= h - self.footer_lines_count():
                    break

                # Build the line: status_char  short_id  priority  title
                attr = curses.A_REVERSE if is_selected else 0

                # Clear the line with highlight if selected
                if is_selected:
                    stdscr.addstr(y, 0, " " * (w - 1), curses.A_REVERSE)

                x = 1
                # Status symbol (colored)
                cpair = color_for_status(t.status_char)
                sym_attr = curses.color_pair(cpair) | (curses.A_REVERSE if is_selected else 0)
                try:
                    stdscr.addstr(y, x, t.status_char, sym_attr)
                except curses.error:
                    pass
                x += 2

                # Short ID (padded to 5 chars)
                id_str = t.short_id.ljust(5)
                try:
                    stdscr.addstr(y, x, id_str, attr)
                except curses.error:
                    pass
                x += len(id_str) + 1

                # Priority + title
                rest = ""
                if t.priority:
                    rest = t.priority + " " + t.title
                else:
                    rest = t.title
                max_rest = w - x - 1
                if len(rest) > max_rest:
                    rest = rest[:max_rest]
                try:
                    stdscr.addstr(y, x, rest, attr)
                except curses.error:
                    pass

        # Footer
        footer_y = h - 1
        if footer_y > row:
            keys = " j/k navigate  enter details  r refresh  q quit"
            try:
                stdscr.addstr(footer_y, 1, keys[:w - 2], curses.A_DIM)
            except curses.error:
                pass

        stdscr.noutrefresh()
        curses.doupdate()

    def render_detail(self):
        stdscr = self.stdscr
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        if h < 3 or w < 10:
            return

        max_lines = h - 3
        total = len(self.detail_lines)

        # Clamp detail scroll
        if self.detail_scroll > total - max_lines:
            self.detail_scroll = max(0, total - max_lines)
        if self.detail_scroll < 0:
            self.detail_scroll = 0

        row = 0
        end = min(self.detail_scroll + max_lines, total)
        for i in range(self.detail_scroll, end):
            line = self.detail_lines[i]
            # Colorize status symbol on first line
            if i == 0 and line and line[0] in STATUS_COLORS:
                cpair = color_for_status(line[0])
                try:
                    stdscr.addstr(row, 1, line[0], curses.color_pair(cpair))
                    rest = line[1:w - 2]
                    stdscr.addstr(row, 2, rest)
                except curses.error:
                    pass
            else:
                display = line[:w - 2]
                try:
                    stdscr.addstr(row, 1, display)
                except curses.error:
                    pass
            row += 1

        # Footer
        footer_y = h - 1
        scroll_hint = ""
        if total > max_lines:
            scroll_hint = "  j/k scroll"
        keys = f" enter/q back{scroll_hint}"
        try:
            stdscr.addstr(footer_y, 1, keys[:w - 2], curses.A_DIM)
        except curses.error:
            pass

        stdscr.noutrefresh()
        curses.doupdate()

    def render(self):
        if self.mode == "list":
            self.render_list()
        else:
            self.render_detail()

    def show_detail(self):
        if not self.tickets or self.cursor >= len(self.tickets):
            return
        ticket = self.tickets[self.cursor]
        text = get_detail(ticket.full_id)
        self.detail_lines = text.split("\n")
        self.detail_scroll = 0
        self.mode = "detail"

    def run(self):
        stdscr = self.stdscr
        curses.curs_set(0)
        self.setup_colors()
        stdscr.timeout(200)  # 200ms non-blocking getch

        self.load_tickets()
        self.render()

        # Start background refresh thread
        bg_thread = threading.Thread(target=self.bg_refresh_loop, daemon=True)
        bg_thread.start()

        last_render = time.time()

        try:
            while True:
                key = stdscr.getch()

                # Auto re-render periodically (to update timestamp and pick up bg data)
                now = time.time()
                need_render = (now - last_render) >= 1.0

                if key == curses.KEY_RESIZE:
                    need_render = True

                elif key == -1:
                    # Timeout, no key pressed
                    if need_render:
                        self.render()
                        last_render = time.time()
                    continue

                if self.mode == "list":
                    count = len(self.tickets)

                    if key in (ord("k"), curses.KEY_UP):
                        if self.cursor > 0:
                            self.cursor -= 1
                            need_render = True

                    elif key in (ord("j"), curses.KEY_DOWN):
                        if self.cursor < count - 1:
                            self.cursor += 1
                            need_render = True

                    elif key in (curses.KEY_ENTER, 10, 13):
                        if count > 0:
                            self.show_detail()
                            need_render = True

                    elif key == ord("r"):
                        self.load_tickets()
                        need_render = True

                    elif key in (ord("q"), 27):  # q or Escape
                        break

                elif self.mode == "detail":
                    total = len(self.detail_lines)
                    h, _ = stdscr.getmaxyx()
                    max_lines = h - 3

                    if key in (ord("j"), curses.KEY_DOWN):
                        if self.detail_scroll < total - max_lines:
                            self.detail_scroll += 1
                            need_render = True

                    elif key in (ord("k"), curses.KEY_UP):
                        if self.detail_scroll > 0:
                            self.detail_scroll -= 1
                            need_render = True

                    elif key in (ord("q"), 27, curses.KEY_ENTER, 10, 13):
                        self.mode = "list"
                        need_render = True

                if need_render:
                    self.render()
                    last_render = time.time()

        finally:
            self._stop_event.set()


def main(stdscr):
    # Accept optional project directory argument (consistent with other watch scripts)
    if len(sys.argv) > 1:
        os.chdir(sys.argv[1])
    app = BeadsTUI(stdscr)
    app.run()


if __name__ == "__main__":
    curses.wrapper(main)
