"""Help overlay screen showing keyboard shortcuts."""

from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Center, Vertical
from textual.screen import ModalScreen
from textual.widgets import Static

HELP_TEXT = """\
[bold]Watch Dashboard — Keyboard Shortcuts[/bold]

[bold underline]Navigation[/bold underline]
  [bold]Tab / Shift+Tab[/bold]  Switch between Deploys / Actions tabs
  [bold]j / Down[/bold]         Move cursor down
  [bold]k / Up[/bold]           Move cursor up
  [bold]Enter[/bold]            Open selected URL in browser

[bold underline]Global[/bold underline]
  [bold]?[/bold]                Show this help
  [bold]r[/bold]                Force refresh current tab
  [bold]q[/bold]                Quit

[bold underline]Deploys Tab[/bold underline]
  [bold]p[/bold]                Configure / change deploy provider
  [bold]d[/bold]                Disable dashboard pane for this project

[bold underline]Tab configuration (.deploy-watch.json)[/bold underline]
  Each tab can be enabled/disabled independently:
    [dim]{ "tabs": { "actions": { "enabled": false } } }[/dim]
  Actions tab accepts an optional repo override:
    [dim]{ "tabs": { "actions": { "repo": "owner/repo" } } }[/dim]

[dim]Auto-refreshes every 30 seconds.[/dim]
[dim]Press Escape to close.[/dim]"""


class HelpScreen(ModalScreen[None]):
    """Modal overlay displaying keyboard shortcuts."""

    DEFAULT_CSS = """
    HelpScreen {
        align: center middle;
    }

    HelpScreen #help-dialog {
        width: 62;
        max-height: 80%;
        background: $surface;
        border: thick $primary;
        padding: 1 2;
    }

    HelpScreen #help-content {
        width: 1fr;
    }
    """

    BINDINGS = [
        Binding("escape", "dismiss", "Close", show=False),
        Binding("question_mark", "dismiss", "Close", show=False),
    ]

    def compose(self) -> ComposeResult:
        with Center():
            with Vertical(id="help-dialog"):
                yield Static(HELP_TEXT, id="help-content")

    def action_dismiss(self) -> None:
        self.dismiss(None)
