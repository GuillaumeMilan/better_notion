use crate::output::Decorate;

#[derive(Debug)]
pub enum CliError {
    Http(String),
    ToolError(String),
    JsonParse(String),
    InvalidArgument(String),
}

impl std::fmt::Display for CliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CliError::Http(msg) => write!(f, "HTTP error: {}", msg),
            CliError::ToolError(msg) => write!(f, "{}", msg),
            CliError::JsonParse(msg) => write!(f, "JSON parse error: {}", msg),
            CliError::InvalidArgument(msg) => write!(f, "Invalid argument: {}", msg),
        }
    }
}

pub trait ResultExt<T> {
    fn unwrap_or_exit(self, context: &str) -> T;
}

impl<T> ResultExt<T> for Result<T, CliError> {
    fn unwrap_or_exit(self, context: &str) -> T {
        match self {
            Ok(val) => val,
            Err(e) => {
                eprintln!("{}", format!("{}: {}", context, e).deco_as_error());
                std::process::exit(1);
            }
        }
    }
}
