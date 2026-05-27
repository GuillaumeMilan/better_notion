use std::path;

use crate::api_client::ApiClient;
use crate::error::ResultExt;
use crate::output::Decorate;

pub fn run(client: &ApiClient, path: &str) {
    let abs = path::absolute(path).expect("Failed to resolve path");
    let result = client
        .call("commit_document", serde_json::json!({ "path": abs.to_string_lossy() }))
        .unwrap_or_exit("Failed to commit document");

    println!("{}", result.deco_as_success());
}
