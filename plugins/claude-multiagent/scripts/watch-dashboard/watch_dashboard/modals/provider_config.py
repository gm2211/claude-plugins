"""Provider configuration modal — collect field values via Input widgets."""

from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, Horizontal
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label
from textual import on

from ..providers import provider_display_name, provider_config_fields


class ProviderConfigModal(ModalScreen[dict | None]):
    """Modal to configure a provider's fields (e.g. API key, project ID)."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    DEFAULT_CSS = """
    ProviderConfigModal {
        align: center middle;
    }

    ProviderConfigModal #config-dialog {
        width: 60;
        max-width: 90%;
        height: auto;
        max-height: 80%;
        background: $surface;
        border: tall $primary;
        padding: 1 2;
    }

    ProviderConfigModal #config-title {
        text-align: center;
        text-style: bold;
        width: 100%;
        margin-bottom: 1;
    }

    ProviderConfigModal .config-field {
        width: 100%;
        height: auto;
        margin: 1 0;
    }

    ProviderConfigModal .config-label {
        width: 100%;
        height: 1;
        text-style: bold;
        padding: 0;
    }

    ProviderConfigModal #config-buttons {
        width: 100%;
        height: auto;
        align-horizontal: center;
        margin-top: 1;
    }

    ProviderConfigModal #config-buttons Button {
        margin: 0 1;
    }
    """

    def __init__(
        self,
        provider: str,
        providers_dir: str,
        initial_values: dict[str, str] | None = None,
    ) -> None:
        super().__init__()
        self._provider = provider
        self._providers_dir = providers_dir
        self._fields = provider_config_fields(provider, providers_dir)
        self._initial_values = initial_values or {}

    def compose(self) -> ComposeResult:
        name = provider_display_name(self._provider, self._providers_dir)
        with Vertical(id="config-dialog"):
            yield Label(f"Configure {name}", id="config-title")
            for field in self._fields:
                key = field["key"]
                label = field.get("label", key)
                default = field.get("default", "")
                initial = str(self._initial_values.get(key, "") or "")
                required = field.get("required", False)
                suffix = " *" if required else ""
                with Vertical(classes="config-field"):
                    yield Label(f"{label}{suffix}", classes="config-label")
                    yield Input(
                        placeholder=default or f"Enter {label}",
                        value=initial or default,
                        id=f"cfg-{key}",
                    )
            with Horizontal(id="config-buttons"):
                yield Button("Save", variant="primary", id="config-save-btn")
                yield Button("Cancel", id="config-cancel-btn")

    @on(Button.Pressed, "#config-save-btn")
    def _on_save(self) -> None:
        values: dict[str, str] = {}
        for field in self._fields:
            key = field["key"]
            required = field.get("required", False)
            default = field.get("default", "")
            inp = self.query_one(f"#cfg-{key}", Input)
            val = inp.value.strip()
            if not val and default:
                val = default
            if required and not val:
                self.notify(f"{field.get('label', key)} is required", severity="error")
                inp.focus()
                return
            values[key] = val
        self.dismiss(values)

    @on(Button.Pressed, "#config-cancel-btn")
    def _on_cancel(self) -> None:
        self.dismiss(None)

    def on_click(self, event) -> None:
        if self is event.widget:
            self.dismiss(None)

    def action_cancel(self) -> None:
        self.dismiss(None)
