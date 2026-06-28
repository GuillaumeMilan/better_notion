use clap::{Parser, Subcommand};
use clap_complete::Shell;

#[derive(Parser, Debug)]
#[command(
    name = "better-notion",
    author,
    version,
    about = "CLI for the Better Notion MCP server"
)]
pub struct Cli {
    /// MCP server URL
    #[arg(long, env = "BETTER_NOTION_URL", default_value = "http://localhost:4000")]
    pub server_url: String,

    /// Enable verbose output
    #[arg(long, short)]
    pub verbose: bool,

    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
    /// Ping the MCP server
    Ping,

    /// Fetch a Notion document and save as markdown
    FetchDocument {
        /// Notion page URL or UUID
        page: String,

        /// Absolute path to save the document
        path: Option<String>,
    },

    /// Commit local document changes back to Notion
    CommitDocument {
        /// Absolute path to the local document file
        path: String,
    },

    /// Fetch entries from a Notion database view
    FetchViewEntries {
        /// Notion database view URL
        view_url: String,

        /// Additional fields to include (comma-separated)
        #[arg(long, short, value_delimiter = ',')]
        additional_fields: Option<Vec<String>>,
    },

    /// Update properties, icon, and/or cover on a Notion page
    UpdateProperties {
        /// Notion page URL or UUID
        page: String,

        /// Properties as a JSON string, e.g. '{"Status": "Done"}'
        #[arg(long, short)]
        properties: Option<String>,

        /// Page icon: an emoji (e.g. "🚀"), a custom emoji name (e.g. ":rocket:"), or an image URL. Use "none" to remove.
        #[arg(long, short)]
        icon: Option<String>,

        /// Page cover: an external image URL. Use "none" to remove.
        #[arg(long, short)]
        cover: Option<String>,
    },

    /// [EXPERIMENTAL] Create a page in a view that matches the view's filters
    CreatePageOnView {
        /// Notion database view URL
        view_url: String,

        /// Title for the new page (default "New page")
        #[arg(long, short)]
        title: Option<String>,
    },

    /// Generate shell completions
    Completions {
        /// The shell to generate completions for
        #[arg(value_enum)]
        shell: Shell,
    },
}
