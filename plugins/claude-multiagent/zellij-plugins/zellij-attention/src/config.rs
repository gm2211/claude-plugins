use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct NotificationConfig {
    pub enabled: bool,
    pub waiting_icon: String,
    pub completed_icon: String,
}

impl Default for NotificationConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            waiting_icon: "⏳".to_string(),
            completed_icon: "✅".to_string(),
        }
    }
}

impl NotificationConfig {
    pub fn from_configuration(config: &BTreeMap<String, String>) -> Self {
        let mut result = Self::default();
        if let Some(enabled) = config.get("enabled") {
            result.enabled = enabled == "true";
        }
        if let Some(icon) = config.get("waiting_icon") {
            if icon.chars().count() > 4 {
                eprintln!("zellij-attention: Warning: waiting_icon '{}' is longer than 4 chars", icon);
            }
            result.waiting_icon = icon.clone();
        }
        if let Some(icon) = config.get("completed_icon") {
            if icon.chars().count() > 4 {
                eprintln!("zellij-attention: Warning: completed_icon '{}' is longer than 4 chars", icon);
            }
            result.completed_icon = icon.clone();
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = NotificationConfig::default();
        assert!(config.enabled);
        assert_eq!(config.waiting_icon, "⏳");
        assert_eq!(config.completed_icon, "✅");
    }

    #[test]
    fn test_from_configuration_empty() {
        let config_map = BTreeMap::new();
        let config = NotificationConfig::from_configuration(&config_map);
        assert!(config.enabled);
        assert_eq!(config.waiting_icon, "⏳");
    }

    #[test]
    fn test_from_configuration_custom() {
        let mut config_map = BTreeMap::new();
        config_map.insert("enabled".to_string(), "true".to_string());
        config_map.insert("waiting_icon".to_string(), "!".to_string());
        config_map.insert("completed_icon".to_string(), "*".to_string());
        let config = NotificationConfig::from_configuration(&config_map);
        assert!(config.enabled);
        assert_eq!(config.waiting_icon, "!");
        assert_eq!(config.completed_icon, "*");
    }

    #[test]
    fn test_from_configuration_disabled() {
        let mut config_map = BTreeMap::new();
        config_map.insert("enabled".to_string(), "false".to_string());
        let config = NotificationConfig::from_configuration(&config_map);
        assert!(!config.enabled);
    }
}
