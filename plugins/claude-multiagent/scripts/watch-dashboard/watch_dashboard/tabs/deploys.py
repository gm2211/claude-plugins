"""Deploys tab — DataTable showing deployment status from configured provider."""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import time

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import DataTable, Static
from textual import work
from rich.text import Text

from ..config import config_read, config_write, config_get_provider, config_remove
from ..providers import (
    list_providers,
    provider_display_name,
    fetch_deploys,
    format_elapsed,
    default_providers_dir,
)

_log = logging.getLogger("watch-dashboard")


# ---------------------------------------------------------------------------
# Status styling helpers
# ---------------------------------------------------------------------------

_STATUS_STYLES: dict[str, str] = {
    "live": "bold #a6e3a1",
    "success": "bold #a6e3a1",
    "building": "bold #f9e2af",
    "deploying": "bold #f9e2af",
    "pending": "bold #f9e2af",
    "failed": "bold #f38ba8",
    "cancelled": "dim",
}


def _status_text(status: str) -> Text:
    style = _STATUS_STYLES.get(status, "")
    return Text(status, style=style)


# ---------------------------------------------------------------------------
# DeploysTab widget
# ---------------------------------------------------------------------------


class DeploysTab(Vertical):
    """Content widget for the Deploys tab."""

    def __init__(
        self,
        project_dir: str,
        providers_dir: str | None = None,
        dash_id: str = "",
    ) -> None:
        super().__init__()
        self._project_dir = project_dir
        self._providers_dir = providers_dir or default_providers_dir()
        self._dash_id = dash_id
        self._config_file = os.path.join(project_dir, ".deploy-watch.json")
        self._cached_records: list[dict] = []
        self._urls: list[str] = []
        self._fetch_error = ""
        self._last_fetch_time = 0

    def compose(self) -> ComposeResult:
        yield Static("", id="deploy-service-url")
        yield DataTable(id="deploy-table", cursor_type="row", zebra_stripes=True)
        yield Static("", id="deploy-status")

    def on_mount(self) -> None:
        table = self.query_one("#deploy-table", DataTable)
        table.add_columns("Commit", "Version", "Message", "Build", "Deploy", "Elapsed")
        self._refresh_data()

    def get_selected_url(self) -> str:
        """Return the URL for the currently selected row, or empty string."""
        table = self.query_one("#deploy-table", DataTable)
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
        """Fetch deploy data from provider in a background thread."""
        provider = config_get_provider(self._config_file)
        if not provider:
            self.app.call_from_thread(self._show_unconfigured)
            return

        records = fetch_deploys(self._config_file, self._providers_dir)
        fetch_error = "Provider error" if records is None else ""
        fetch_time = int(time.time())

        def _apply() -> None:
            self._fetch_error = fetch_error
            if records is not None:
                self._cached_records = records
            self._last_fetch_time = fetch_time
            self._populate_table()

        self.app.call_from_thread(_apply)

    def _show_unconfigured(self) -> None:
        """Show unconfigured state."""
        table = self.query_one("#deploy-table", DataTable)
        table.clear()
        self._urls = []
        providers = list_providers(self._providers_dir)
        if providers:
            names = ", ".join(providers)
            msg = f"Not configured. Press [bold]p[/bold] to select a provider.\nAvailable: {names}"
        else:
            msg = f"Not configured. No providers found in {self._providers_dir}"

        self.query_one("#deploy-status", Static).update(msg)
        self.query_one("#deploy-service-url", Static).update("")

    def _populate_table(self) -> None:
        """Populate the DataTable with cached records."""
        table = self.query_one("#deploy-table", DataTable)
        table.clear()
        self._urls = []

        records = self._cached_records
        if not records and not self._fetch_error:
            provider = config_get_provider(self._config_file)
            if not provider:
                self._show_unconfigured()
                return

        # Service URL display
        service_url = ""
        for rec in records:
            if rec.get("service_url"):
                service_url = rec["service_url"]
                break
        url_widget = self.query_one("#deploy-service-url", Static)
        url_widget.update(Text(service_url, style="#89b4fa") if service_url else "")

        for rec in records:
            commit = Text(rec.get("commit", "")[:7], style="bold")
            version_str = rec.get("tag", "") or rec.get("version", "")
            version = Text(version_str, style="#cba6f7") if version_str else Text("")
            msg = rec.get("message", "")
            if len(msg) > 50:
                msg = msg[:48] + ".."
            message = Text(msg)
            build = _status_text(rec.get("build_status", ""))
            deploy = _status_text(rec.get("deploy_status", ""))
            elapsed = Text(format_elapsed(rec), style="dim")

            table.add_row(commit, version, message, build, deploy, elapsed)
            self._urls.append(rec.get("service_url", ""))

        # Status line
        ts = time.strftime("%H:%M:%S")
        provider = config_get_provider(self._config_file)
        name = provider_display_name(provider, self._providers_dir) if provider else "—"
        if self._fetch_error:
            status = f"[bold red]{self._fetch_error}[/bold red] | Provider: {name} | {ts}"
        else:
            status = f"Provider: {name} | Updated {ts}"
        self.query_one("#deploy-status", Static).update(status)

    def refresh_data(self) -> None:
        """Public trigger for refresh."""
        self._refresh_data()

    def configure_provider(self) -> None:
        """Launch provider picker → config flow."""
        from ..modals.provider_picker import ProviderPicker

        def _on_pick(provider: str | None) -> None:
            if provider is None:
                return
            self._configure_provider_fields(provider)

        self.app.push_screen(ProviderPicker(self._providers_dir), callback=_on_pick)

    def _configure_provider_fields(self, provider: str) -> None:
        """Show config fields modal for the selected provider."""
        from ..modals.provider_config import ProviderConfigModal

        def _on_config(values: dict | None) -> None:
            if values is None:
                return
            cfg = {
                "provider": provider,
                provider: values,
            }
            config_write(self._config_file, cfg)
            self.app.notify(f"Provider configured: {provider}")
            self._refresh_data()

        self.app.push_screen(
            ProviderConfigModal(provider, self._providers_dir),
            callback=_on_config,
        )

    def manage_provider(self) -> None:
        """Show provider management options (change/remove)."""
        provider = config_get_provider(self._config_file)
        if not provider:
            self.configure_provider()
            return
        # Provider is configured — offer change or remove
        from ..modals.provider_manage import ProviderManageModal

        name = provider_display_name(provider, self._providers_dir)

        def _on_manage(action: str | None) -> None:
            if action == "change":
                self.configure_provider()
            elif action == "remove":
                config_remove(self._config_file)
                self._cached_records = []
                self._urls = []
                self.app.notify("Provider removed.")
                self._show_unconfigured()

        self.app.push_screen(ProviderManageModal(name), callback=_on_manage)

    def disable_dashboard_pane(self) -> None:
        """Disable the dashboard pane for this project and exit."""
        config_path = os.path.join(
            self._project_dir, ".claude", "claude-multiagent.local.md"
        )
        os.makedirs(os.path.dirname(config_path), exist_ok=True)

        existing = ""
        try:
            with open(config_path, "r") as f:
                existing = f.read()
        except FileNotFoundError:
            pass

        if "dashboard_pane: disabled" not in existing:
            with open(config_path, "a") as f:
                if existing and not existing.endswith("\n"):
                    f.write("\n")
                f.write("dashboard_pane: disabled\n")

        self.app.notify("Dashboard pane disabled. Edit .claude/claude-multiagent.local.md to re-enable.")
        self.app.set_timer(2.0, self.app.exit)
