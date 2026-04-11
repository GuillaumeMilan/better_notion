use crate::api_client::ApiClient;
use crate::error::{CliError, ResultExt};
use crate::output::Decorate;

pub fn run(client: &ApiClient, page: &str, properties_json: &str) {
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

    let result = client
        .call(
            "update_properties",
            serde_json::json!({ "page": page, "properties": properties }),
        )
        .unwrap_or_exit("Failed to update properties");

    println!("{}", result.deco_as_success());
}
