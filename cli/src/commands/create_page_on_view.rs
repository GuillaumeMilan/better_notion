use crate::api_client::ApiClient;
use crate::error::ResultExt;
use crate::output::Decorate;
use colored::Colorize;

pub fn run(client: &ApiClient, view_url: &str, title: Option<&str>) {
    let mut args = serde_json::json!({ "view_url": view_url });
    if let Some(title) = title {
        args["title"] = serde_json::Value::String(title.to_string());
    }

    let result = client
        .call("create_page_on_view", args)
        .unwrap_or_exit("Failed to create page on view");

    // The server returns JSON: { page_id, url, warnings }
    match serde_json::from_str::<serde_json::Value>(&result) {
        Ok(parsed) => {
            if let Some(url) = parsed.get("url").and_then(|v| v.as_str()) {
                println!("{}", format!("Created page: {}", url).deco_as_success());
            }

            if let Some(warnings) = parsed.get("warnings").and_then(|v| v.as_array()) {
                for warning in warnings.iter().filter_map(|w| w.as_str()) {
                    println!("{} {}", "[warning]".yellow().bold(), warning);
                }
            }
        }
        Err(_) => println!("{}", result),
    }
}
