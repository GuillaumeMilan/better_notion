use crate::api_client::ApiClient;
use crate::error::{CliError, ResultExt};
use crate::output::Decorate;

pub fn run(
    client: &ApiClient,
    page: &str,
    properties_json: Option<&str>,
    icon: Option<&str>,
    cover: Option<&str>,
) {
    if properties_json.is_none() && icon.is_none() && cover.is_none() {
        eprintln!(
            "{}",
            "Nothing to update: provide --properties, --icon, and/or --cover".deco_as_error()
        );
        std::process::exit(1);
    }

    let mut payload = serde_json::Map::new();
    payload.insert(
        "page".to_string(),
        serde_json::Value::String(page.to_string()),
    );

    if let Some(properties_json) = properties_json {
        let properties: serde_json::Value = serde_json::from_str(properties_json)
            .map_err(|e| CliError::InvalidArgument(format!("Invalid JSON for properties: {}", e)))
            .unwrap_or_exit("Invalid properties");

        if !properties.is_object() {
            eprintln!(
                "{}",
                "Properties must be a JSON object, e.g. '{\"Status\": \"Done\"}'".deco_as_error()
            );
            std::process::exit(1);
        }

        payload.insert("properties".to_string(), properties);
    }

    if let Some(icon) = icon {
        payload.insert(
            "icon".to_string(),
            serde_json::Value::String(icon.to_string()),
        );
    }

    if let Some(cover) = cover {
        payload.insert(
            "cover".to_string(),
            serde_json::Value::String(cover.to_string()),
        );
    }

    let result = client
        .call("update_properties", serde_json::Value::Object(payload))
        .unwrap_or_exit("Failed to update page");

    println!("{}", result.deco_as_success());
}
