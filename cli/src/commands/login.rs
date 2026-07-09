use crate::api_client::ApiClient;
use crate::error::ResultExt;
use crate::output::Decorate;

pub fn run(client: &ApiClient) {
    let auth_url = client
        .call("login", serde_json::json!({ "base_url": client.base_url() }))
        .unwrap_or_exit("Login failed");

    println!("To connect Better Notion to your Notion workspace, open this URL in your browser:\n");
    println!("{}", auth_url.deco_as_path());
    println!("\nAfter you approve access, you can return here and run your command again.");
}
