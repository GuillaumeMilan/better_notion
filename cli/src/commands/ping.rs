use crate::api_client::ApiClient;
use crate::error::ResultExt;
use crate::output::Decorate;

pub fn run(client: &ApiClient) {
    let result = client
        .call("ping", serde_json::json!({}))
        .unwrap_or_exit("Ping failed");

    println!("{}", result.deco_as_success());
}
