mod api_client;
mod cli;
mod commands;
mod error;
mod output;

use clap::Parser;
use cli::{Cli, Commands};

fn main() {
    let args = Cli::parse();
    let client = api_client::ApiClient::new(&args.server_url, args.verbose);

    match args.command {
        Commands::Ping => commands::ping::run(&client),
        Commands::FetchDocument { page, path } => {
            commands::fetch_document::run(&client, &page, path.as_deref())
        }
        Commands::CommitDocument { path } => commands::commit_document::run(&client, &path),
        Commands::FetchViewEntries {
            view_url,
            additional_fields,
        } => commands::fetch_view_entries::run(&client, &view_url, additional_fields),
        Commands::UpdateProperties { page, properties } => {
            commands::update_properties::run(&client, &page, &properties)
        }
        Commands::Completions { shell } => commands::completions::run(shell),
    }
}
