use crate::error::CliError;
use crate::output;

pub struct ApiClient {
    base_url: String,
    verbose: bool,
}

impl ApiClient {
    pub fn new(base_url: &str, verbose: bool) -> Self {
        ApiClient {
            base_url: base_url.trim_end_matches('/').to_string(),
            verbose,
        }
    }

    pub fn call(&self, endpoint: &str, body: serde_json::Value) -> Result<String, CliError> {
        let url = format!("{}/api/{}", self.base_url, endpoint);

        output::explain(&self.verbose, &format!("POST {}", url));
        output::explain(&self.verbose, &format!("Body: {}", body));

        let mut response = ureq::post(&url)
            .header("Content-Type", "application/json")
            .send_json(&body)
            .map_err(|e| CliError::Http(e.to_string()))?;

        let response_body: serde_json::Value = response
            .body_mut()
            .read_json()
            .map_err(|e| CliError::JsonParse(e.to_string()))?;

        output::explain(&self.verbose, &format!("Response: {}", response_body));

        let ok = response_body
            .get("ok")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        if ok {
            response_body
                .get("text")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .ok_or_else(|| CliError::JsonParse("Missing 'text' field in response".into()))
        } else {
            let error = response_body
                .get("error")
                .and_then(|v| v.as_str())
                .unwrap_or("Unknown error")
                .to_string();
            Err(CliError::ToolError(error))
        }
    }
}
