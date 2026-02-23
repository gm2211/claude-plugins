"""Main Textual application — tabbed dashboard for Deploys + GitHub Actions."""

from __future__ import annotations

import logging
import os
import platform
import shutil
import subprocess

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.widgets import DataTable, Footer, Header, TabbedContent, TabPane

from .modals.help_screen import HelpScreen
from .tabs.deploys import DeploysTab
from .tabs.actions import ActionsTab

_log = logging.getLogger("watch-dashboard")

POLL_INTERVAL = 30


class WatchDashboardApp(App):
    """Tabbed dashboard: Deploys + GitHub Actions."""

    TITLE = "Watch Dashboard"
    CSS_PATH = "styles/app.tcss"
    ENABLE_COMMAND_PALETTE = False

    BINDINGS = [
        Binding("q", "quit", "Quit", priority=True),
        Binding("question_mark", "help", "Help", key_display="?"),
        Binding("r", "refresh", "Refresh"),
        Binding("p", "provider_config", "Provider", show=False),
        Binding("d", "disable_deploy", "Disable", show=False),
        Binding("j", "cursor_down", "Down", show=False),
        Binding("k", "cursor_up", "Up", show=False),
        Binding("enter", "open_url", "Open URL", show=False),
    ]

    def __init__(
        self,
        project_dir: str,
        providers_dir: str | None = None,
        dash_id: str = "",
    ) -> None:
        super().__init__()
        self._project_dir = project_dir
        self._providers_dir = providers_dir
        self._dash_id = dash_id
        self._poll_timer = None

    def compose(self) -> ComposeResult:
        yield Header(icon="")
        with TabbedContent(id="tabs"):
            with TabPane("Deploys", id="deploys-pane"):
                yield DeploysTab(
                    project_dir=self._project_dir,
                    providers_dir=self._providers_dir,
                    dash_id=self._dash_id,
                )
            with TabPane("Actions", id="actions-pane"):
                yield ActionsTab(project_dir=self._project_dir)
        yield Footer()

    def on_mount(self) -> None:
        self._poll_timer = self.set_interval(
            POLL_INTERVAL, self._poll_refresh, name="poll-refresh"
        )

    def _poll_refresh(self) -> None:
        """Timer-driven refresh of the active tab."""
        self._refresh_active_tab()

    def _get_active_tab_id(self) -> str:
        """Return the ID of the currently active tab pane."""
        tabbed = self.query_one("#tabs", TabbedContent)
        return str(tabbed.active)

    def _refresh_active_tab(self) -> None:
        """Refresh the currently visible tab."""
        active = self._get_active_tab_id()
        if active == "deploys-pane":
            self.query_one(DeploysTab).refresh_data()
        elif active == "actions-pane":
            self.query_one(ActionsTab).refresh_data()

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def action_help(self) -> None:
        self.push_screen(HelpScreen())

    def action_refresh(self) -> None:
        self._refresh_active_tab()

    def action_provider_config(self) -> None:
        active = self._get_active_tab_id()
        if active == "deploys-pane":
            self.query_one(DeploysTab).manage_provider()

    def action_disable_deploy(self) -> None:
        active = self._get_active_tab_id()
        if active == "deploys-pane":
            self.query_one(DeploysTab).disable_dashboard_pane()

    def action_cursor_down(self) -> None:
        active = self._get_active_tab_id()
        if active == "deploys-pane":
            table = self.query_one("#deploy-table", DataTable)
            if table.row_count > 0:
                table.action_cursor_down()
        elif active == "actions-pane":
            table = self.query_one("#actions-table", DataTable)
            if table.row_count > 0:
                table.action_cursor_down()

    def action_cursor_up(self) -> None:
        active = self._get_active_tab_id()
        if active == "deploys-pane":
            table = self.query_one("#deploy-table", DataTable)
            if table.row_count > 0:
                table.action_cursor_up()
        elif active == "actions-pane":
            table = self.query_one("#actions-table", DataTable)
            if table.row_count > 0:
                table.action_cursor_up()

    def action_open_url(self) -> None:
        active = self._get_active_tab_id()
        url = ""
        if active == "deploys-pane":
            url = self.query_one(DeploysTab).get_selected_url()
        elif active == "actions-pane":
            url = self.query_one(ActionsTab).get_selected_url()
        if url:
            _open_url(url)


def _open_url(url: str) -> None:
    """Open a URL in the default browser."""
    if not url:
        return
    opener = "open" if platform.system() == "Darwin" else "xdg-open"
    if shutil.which(opener):
        try:
            subprocess.Popen(
                [opener, url],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass
