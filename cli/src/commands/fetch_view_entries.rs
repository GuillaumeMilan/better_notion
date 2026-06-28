use crate::api_client::ApiClient;
use crate::error::ResultExt;

pub fn run(client: &ApiClient, view_url: &str, additional_fields: Option<Vec<String>>) {
    let mut args = serde_json::json!({ "view_url": view_url });

    if let Some(fields) = additional_fields {
        args["additional_fields"] =
            serde_json::Value::Array(fields.into_iter().map(serde_json::Value::String).collect());
    }

    let result = client
        .call("fetch_view_entries", args)
        .unwrap_or_exit("Failed to fetch view entries");

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
