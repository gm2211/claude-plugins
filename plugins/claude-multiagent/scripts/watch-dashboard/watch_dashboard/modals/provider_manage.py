"""Provider management modal — change or remove the current provider."""

from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, Horizontal
from textual.screen import ModalScreen
from textual.widgets import Button, Label
from textual import on


class ProviderManageModal(ModalScreen[str | None]):
    """Modal offering change/remove options for the current provider."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    DEFAULT_CSS = """
    ProviderManageModal {
        align: center middle;
    }

    ProviderManageModal #manage-dialog {
        width: 50;
        max-width: 80%;
        height: auto;
        background: $surface;
        border: tall $primary;
        padding: 1 2;
    }

    ProviderManageModal #manage-title {
        text-align: center;
        text-style: bold;
        width: 100%;
        margin-bottom: 1;
    }

    ProviderManageModal #manage-buttons {
        width: 100%;
        height: auto;
        align-horizontal: center;
        margin-top: 1;
    }

    ProviderManageModal #manage-buttons Button {
        margin: 0 1;
    }
    """

    def __init__(self, provider_name: str) -> None:
        super().__init__()
        self._provider_name = provider_name

    def compose(self) -> ComposeResult:
        with Vertical(id="manage-dialog"):
            yield Label(f"Current provider: {self._provider_name}", id="manage-title")
            with Horizontal(id="manage-buttons"):
                yield Button("Configure", variant="primary", id="manage-configure-btn")
                yield Button("Change", id="manage-change-btn")
                yield Button("Remove", variant="error", id="manage-remove-btn")
                yield Button("Cancel", id="manage-cancel-btn")

    @on(Button.Pressed, "#manage-configure-btn")
    def _on_configure(self) -> None:
        self.dismiss("configure")

    @on(Button.Pressed, "#manage-change-btn")
    def _on_change(self) -> None:
        self.dismiss("change")

    @on(Button.Pressed, "#manage-remove-btn")
    def _on_remove(self) -> None:
        self.dismiss("remove")

    @on(Button.Pressed, "#manage-cancel-btn")
    def _on_cancel(self) -> None:
        self.dismiss(None)

    def on_click(self, event) -> None:
        if self is event.widget:
            self.dismiss(None)

    def action_cancel(self) -> None:
        self.dismiss(None)
