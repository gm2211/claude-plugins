pub mod config;
pub mod state;

#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashMap};
use zellij_tile::prelude::*;
use zellij_tile::shim::{rename_tab, unblock_cli_pipe_input};

use crate::config::NotificationConfig;
use crate::state::NotificationType;

#[derive(Default)]
pub struct State {
    permissions_granted: bool,
    pub(crate) tabs: Vec<TabInfo>,
    pub(crate) panes: PaneManifest,
    pub(crate) notification_state: HashMap<u32, NotificationType>,
    pub(crate) original_tab_names: HashMap<usize, String>,
    pub(crate) config: NotificationConfig,
    updating_tabs: bool,
    pub(crate) pending_strips: std::collections::HashSet<usize>,
}

impl State {
    fn determine_focused_pane(&self) -> Option<u32> {
        let active_tab = self.tabs.iter().find(|t| t.active)?;
        let panes = self.panes.panes.get(&active_tab.position)?;
        let focused = panes.iter().find(|p| {
            !p.is_plugin && p.is_focused && (p.is_floating == active_tab.are_floating_panes_visible)
        })?;
        Some(focused.id)
    }

    pub(crate) fn check_and_clear_focus(&mut self) -> bool {
        if let Some(focused_pane_id) = self.determine_focused_pane() {
            if self.notification_state.remove(&focused_pane_id).is_some() {
                return true;
            }
        }
        false
    }

    pub(crate) fn clean_stale_notifications(&mut self) -> bool {
        if self.notification_state.is_empty() || self.panes.panes.is_empty() {
            return false;
        }
        let current_pane_ids: std::collections::HashSet<u32> = self.panes.panes.values()
            .flat_map(|panes| panes.iter().filter(|p| !p.is_plugin).map(|p| p.id))
            .collect();
        let stale_ids: Vec<u32> = self.notification_state.keys()
            .filter(|id| !current_pane_ids.contains(id))
            .copied()
            .collect();
        if stale_ids.is_empty() { return false; }
        for id in &stale_ids { self.notification_state.remove(id); }
        true
    }

    pub(crate) fn tab_name_has_icon(&self, name: &str) -> bool {
        let waiting_suffix = format!(" {}", self.config.waiting_icon);
        let completed_suffix = format!(" {}", self.config.completed_icon);
        name.ends_with(&waiting_suffix) || name.ends_with(&completed_suffix)
    }

    pub(crate) fn strip_icons(&self, name: &str) -> String {
        let mut result = name.to_string();
        for icon in [&self.config.waiting_icon, &self.config.completed_icon] {
            let suffix = format!(" {}", icon);
            while result.ends_with(&suffix) {
                result.truncate(result.len() - suffix.len());
            }
        }
        result
    }

    pub(crate) fn get_tab_notification_state(&self, tab_position: usize) -> Option<NotificationType> {
        let panes = self.panes.panes.get(&tab_position)?;
        let mut has_completed = false;
        for pane in panes {
            if pane.is_plugin { continue; }
            if let Some(&notification) = self.notification_state.get(&pane.id) {
                if notification == NotificationType::Waiting {
                    return Some(NotificationType::Waiting);
                }
                if notification == NotificationType::Completed {
                    has_completed = true;
                }
            }
        }
        if has_completed { Some(NotificationType::Completed) } else { None }
    }

    fn update_tab_names(&mut self) {
        if self.updating_tabs || !self.config.enabled { return; }
        self.updating_tabs = true;

        let mut notified_positions: std::collections::HashSet<usize> = std::collections::HashSet::new();

        for tab in &self.tabs {
            if let Some(notification) = self.get_tab_notification_state(tab.position) {
                notified_positions.insert(tab.position);
                if !self.original_tab_names.contains_key(&tab.position) {
                    let original = if tab.name.is_empty() {
                        format!("Tab #{}", tab.position + 1)
                    } else {
                        self.strip_icons(&tab.name)
                    };
                    self.original_tab_names.insert(tab.position, original);
                }
                let icon = match notification {
                    NotificationType::Waiting => &self.config.waiting_icon,
                    NotificationType::Completed => &self.config.completed_icon,
                };
                let original = self.original_tab_names.get(&tab.position)
                    .cloned().unwrap_or_else(|| format!("Tab #{}", tab.position + 1));
                let new_name = format!("{} {}", original, icon);
                if tab.name != new_name {
                    rename_tab((tab.position + 1) as u32, &new_name);
                }
            }
        }

        let positions_to_restore: Vec<usize> = self.original_tab_names.keys()
            .filter(|pos| !notified_positions.contains(pos))
            .cloned().collect();
        for pos in positions_to_restore {
            if let Some(tab) = self.tabs.iter().find(|t| t.position == pos) {
                if let Some(original_name) = self.original_tab_names.remove(&pos) {
                    if tab.name != original_name {
                        rename_tab((pos + 1) as u32, &original_name);
                    }
                }
            }
        }

        for tab in &self.tabs {
            if notified_positions.contains(&tab.position) {
                self.pending_strips.remove(&tab.position);
                continue;
            }
            if self.original_tab_names.contains_key(&tab.position) {
                self.pending_strips.remove(&tab.position);
                continue;
            }
            if self.pending_strips.contains(&tab.position) {
                if !self.tab_name_has_icon(&tab.name) {
                    self.pending_strips.remove(&tab.position);
                }
                continue;
            }
            if self.tab_name_has_icon(&tab.name) {
                let clean_name = self.strip_icons(&tab.name);
                eprintln!("zellij-attention: Stripping stale icon from tab pos={} '{}' -> '{}'", tab.position, tab.name, clean_name);
                self.pending_strips.insert(tab.position);
                rename_tab((tab.position + 1) as u32, &clean_name);
            }
        }

        if !self.tabs.is_empty() {
            let valid_positions: std::collections::HashSet<usize> = self.tabs.iter().map(|t| t.position).collect();
            self.original_tab_names.retain(|pos, _| valid_positions.contains(pos));
            self.pending_strips.retain(|pos| valid_positions.contains(pos));
        }

        self.updating_tabs = false;
    }
}

impl ZellijPlugin for State {
    fn load(&mut self, configuration: BTreeMap<String, String>) {
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
            PermissionType::MessageAndLaunchOtherPlugins,
            PermissionType::ReadCliPipes,
        ]);
        subscribe(&[
            EventType::PermissionRequestResult,
            EventType::TabUpdate,
            EventType::PaneUpdate,
        ]);
        self.config = NotificationConfig::from_configuration(&configuration);
        eprintln!("zellij-attention: v{} loaded\n", env!("CARGO_PKG_VERSION"));
    }

    fn update(&mut self, event: Event) -> bool {
        match event {
            Event::PermissionRequestResult(status) => {
                self.permissions_granted = status == PermissionStatus::Granted;
                set_selectable(false);
                self.update_tab_names();
                true
            }
            Event::TabUpdate(tab_info) => {
                self.tabs = tab_info;
                self.check_and_clear_focus();
                self.clean_stale_notifications();
                self.update_tab_names();
                false
            }
            Event::PaneUpdate(pane_manifest) => {
                self.panes = pane_manifest;
                self.check_and_clear_focus();
                self.clean_stale_notifications();
                self.update_tab_names();
                false
            }
            _ => false,
        }
    }

    fn render(&mut self, _rows: usize, _cols: usize) {}

    fn pipe(&mut self, pipe_message: PipeMessage) -> bool {
        let message = if pipe_message.name.starts_with("zellij-attention::") {
            pipe_message.name.clone()
        } else if let Some(ref payload) = pipe_message.payload {
            if payload.starts_with("zellij-attention::") {
                payload.clone()
            } else {
                return false;
            }
        } else {
            return false;
        };

        let parts: Vec<&str> = message.split("::").collect();
        let (event_type, pane_id) = if parts.len() >= 3 {
            let event_type = parts[1].to_string();
            let pane_id: u32 = match parts[2].parse() {
                Ok(n) => n,
                Err(_) => {
                    eprintln!("zellij-attention: Invalid pane_id: {}\n", parts[2]);
                    unblock_cli_pipe_input(&pipe_message.name);
                    return false;
                }
            };
            (event_type, pane_id)
        } else {
            eprintln!("zellij-attention: Invalid format. Use: zellij-attention::EVENT_TYPE::PANE_ID\n");
            unblock_cli_pipe_input(&pipe_message.name);
            return false;
        };

        let notification_type = match event_type.to_lowercase().as_str() {
            "waiting" => NotificationType::Waiting,
            "completed" => NotificationType::Completed,
            unknown => {
                eprintln!("zellij-attention: Unknown event type: {}\n", unknown);
                unblock_cli_pipe_input(&pipe_message.name);
                return false;
            }
        };

        unblock_cli_pipe_input(&pipe_message.name);

        self.notification_state.insert(pane_id, notification_type);

        self.update_tab_names();
        false
    }
}
