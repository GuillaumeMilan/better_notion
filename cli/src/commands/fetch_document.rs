use crate::api_client::ApiClient;
use crate::error::ResultExt;
use crate::output::Decorate;

pub fn run(client: &ApiClient, page: &str, path: Option<&str>) {
    let mut args = serde_json::json!({ "page": page });

    if let Some(p) = path {
        args["path"] = serde_json::Value::String(p.to_string());
    }

    let result = client
        .call("fetch_document", args)
        .unwrap_or_exit("Failed to fetch document");

    println!("Document saved to {}", result.deco_as_path());
}
