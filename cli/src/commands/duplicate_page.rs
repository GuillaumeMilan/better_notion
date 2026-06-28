use crate::api_client::ApiClient;
use crate::error::ResultExt;
use crate::output::Decorate;

pub fn run(client: &ApiClient, page: &str) {
    let result = client
        .call("duplicate_page", serde_json::json!({ "page": page }))
        .unwrap_or_exit("Failed to duplicate page");

    // The server returns JSON: { page_id, url }
    match serde_json::from_str::<serde_json::Value>(&result) {
        Ok(parsed) => match parsed.get("url").and_then(|v| v.as_str()) {
            Some(url) => println!("{}", format!("Duplicated page: {}", url).deco_as_success()),
            None => println!("{}", result),
        },
        Err(_) => println!("{}", result),
    }
}
