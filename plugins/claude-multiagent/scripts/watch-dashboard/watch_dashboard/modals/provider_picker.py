"""Provider selection modal."""

from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, Horizontal
from textual.screen import ModalScreen
from textual.widgets import Button, Label, OptionList
from textual.widgets.option_list import Option
from textual import on

from ..providers import list_providers, provider_display_name


class ProviderPicker(ModalScreen[str | None]):
    """Modal to select a deploy provider from available providers."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    DEFAULT_CSS = """
    ProviderPicker {
        align: center middle;
    }

    ProviderPicker #picker-dialog {
        width: 50;
        max-width: 80%;
        height: auto;
        max-height: 70%;
        background: $surface;
        border: tall $primary;
        padding: 1 2;
    }

    ProviderPicker #picker-title {
        text-align: center;
        text-style: bold;
        width: 100%;
        margin-bottom: 1;
    }

    ProviderPicker #picker-buttons {
        width: 100%;
        height: auto;
        align-horizontal: center;
        margin-top: 1;
    }

    ProviderPicker #picker-buttons Button {
        margin: 0 1;
    }
    """

    def __init__(self, providers_dir: str) -> None:
        super().__init__()
        self._providers_dir = providers_dir

    def compose(self) -> ComposeResult:
        providers = list_providers(self._providers_dir)
        with Vertical(id="picker-dialog"):
            yield Label("Select a Deploy Provider", id="picker-title")
            if providers:
                options = [
                    Option(
                        provider_display_name(p, self._providers_dir),
                        id=p,
                    )
                    for p in providers
                ]
                yield OptionList(*options, id="picker-options")
            else:
                yield Label(f"No providers found in:\n{self._providers_dir}")
            with Horizontal(id="picker-buttons"):
                yield Button("Cancel", id="picker-cancel-btn")

    def on_mount(self) -> None:
        try:
            self.query_one("#picker-options", OptionList).focus()
        except Exception:
            pass

    @on(OptionList.OptionSelected)
    def _on_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.dismiss(str(event.option.id))

    @on(Button.Pressed, "#picker-cancel-btn")
    def _on_cancel(self) -> None:
        self.dismiss(None)

    def on_click(self, event) -> None:
        if self is event.widget:
            self.dismiss(None)

    def action_cancel(self) -> None:
        self.dismiss(None)
