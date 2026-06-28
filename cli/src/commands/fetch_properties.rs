use crate::api_client::ApiClient;
use crate::error::ResultExt;

pub fn run(client: &ApiClient, page: &str) {
    let result = client
        .call("fetch_properties", serde_json::json!({ "page": page }))
        .unwrap_or_exit("Failed to fetch properties");

    // The server returns JSON inside the text field — pretty-print it
    match serde_json::from_str::<serde_json::Value>(&result) {
        Ok(parsed) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&parsed).unwrap_or(result)
            );
        }
        Err(_) => println!("{}", result),
    }
}
