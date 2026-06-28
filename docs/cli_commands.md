# Better Notion CLI

A command-line interface for interacting with Notion through the Better Notion MCP server. Fetch documents as markdown, edit them locally, and commit changes back to Notion.

## Installation

**Prerequisites:** [Rust toolchain](https://rustup.rs/) (cargo)

```bash
cd cli
./install.sh
```

This builds the release binary, installs it to `/usr/local/bin/better-notion`, and sets up shell completions for your current shell.

Options:
- `./install.sh --clean` — clean build artifacts first
- `./install.sh --binary-only` — skip shell completion setup
- `./install.sh --completions-only` — only install completions (binary must already be in PATH)

## Getting Started

The CLI requires the Better Notion server to be running:

```bash
# Start the server (from the project root)
mix run --no-halt
```

Then in another terminal:

```bash
# Verify connectivity
better-notion ping

# Fetch a Notion page as markdown
better-notion fetch-document https://notion.so/My-Page-abc123 --path ./my-page.md

# Edit the file with your editor, then commit back
better-notion commit-document ./my-page.md

# Browse a database view
better-notion fetch-view-entries "https://notion.so/...?v=VIEW_ID"

# Update page properties
better-notion update-properties https://notion.so/My-Page-abc123 \
  --properties '{"Status": "Done", "Priority": 1}'
```

## Global Options

| Option | Env Variable | Default | Description |
|---|---|---|---|
| `--server-url <URL>` | `BETTER_NOTION_URL` | `http://localhost:4000` | Base URL of the Better Notion server |
| `--verbose` / `-v` | | | Print debug output (HTTP requests, responses) |

---

## ping

Test connectivity to the Better Notion server.

**Usage:**

```
better-notion ping
```

**Parameters:** None

**Output:** `pong` if the server is reachable.

---

## fetch-document

Fetch a Notion document and save it as a local markdown file.

**Usage:**

```
better-notion fetch-document <PAGE> [--path <PATH>]
```

**Parameters:**

| Name | Required | Description |
|---|---|---|
| `PAGE` | Yes | Notion page URL (e.g. `https://notion.so/My-Page-abc123`) or page UUID |
| `--path` / `-p` | No | Absolute path where the document should be saved. If omitted, the server creates a temporary file. Prefer providing a path when you intend to edit and commit the document back. |

**Output:** The absolute path where the document was saved.

**Notes:**
- The server stores metadata alongside the file to track the original content for conflict detection on commit.
- The path must be absolute.

---

## commit-document

Commit local changes to a previously fetched Notion document back to Notion.

**Usage:**

```
better-notion commit-document <PATH>
```

**Parameters:**

| Name | Required | Description |
|---|---|---|
| `PATH` | Yes | Absolute path to the local document file (previously fetched with `fetch-document`) |

**Output:** Success confirmation, or conflict details if a 3-way merge conflict is detected between local changes, the original fetched content, and any remote changes made since the fetch.

**Notes:**
- On success, the local file and its metadata are removed.
- If conflicts are detected, the output contains the diff for manual resolution. Resolve the conflicts in the file and run `commit-document` again.

---

## fetch-view-entries

Fetch entries from a Notion database view.

**Usage:**

```
better-notion fetch-view-entries <VIEW_URL> [--additional-fields <FIELDS>]
```

**Parameters:**

| Name | Required | Description |
|---|---|---|
| `VIEW_URL` | Yes | Notion database view URL (must contain a view ID query parameter) |
| `--additional-fields` / `-a` | No | Comma-separated list of additional field names to include beyond the view's default display properties. Use `other_fields` from a previous response to know which fields are available. |

**Output:** JSON object with the following structure:

```json
{
  "has_more": false,
  "results": [ ... ],
  "other_fields": ["Field A", "Field B"]
}
```

- `results` — Array of database entries with their properties.
- `has_more` — Whether more results are available beyond this page.
- `other_fields` — Field names available in the database but not included in the current results. Pass these to `--additional-fields` to include them.

---

## update-properties

Update properties, icon, and/or cover on a Notion page. At least one of `--properties`, `--icon`, or `--cover` must be provided.

**Usage:**

```
better-notion update-properties <PAGE> [--properties <JSON>] [--icon <ICON>] [--cover <URL>]
```

**Parameters:**

| Name | Required | Description |
|---|---|---|
| `PAGE` | Yes | Notion page URL or page UUID |
| `--properties` / `-p` | No | JSON object mapping property names to values. Values must be strings, numbers, or null. |
| `--icon` / `-i` | No | Page icon: an emoji (e.g. `🚀`), a custom emoji name (e.g. `:rocket:`), or an external image URL. Use `none` to remove. |
| `--cover` / `-c` | No | Page cover: an external image URL. Use `none` to remove. |

**Examples:**

```
# Set just the page emoji
better-notion update-properties https://notion.so/My-Page-abc123 --icon 🚀

# Update a property and the icon together
better-notion update-properties https://notion.so/My-Page-abc123 -p '{"Status": "Done"}' -i ✅
```

**Property value formats:**

| Type | Format | Example |
|---|---|---|
| Text/Number | Direct value | `{"Status": "Done", "Priority": 1}` |
| Checkbox | `"__YES__"` or `"__NO__"` | `{"Archived": "__YES__"}` |
| Date start | `"date:{name}:start"` key | `{"date:Due:start": "2025-01-15"}` |
| Date end | `"date:{name}:end"` key | `{"date:Due:end": "2025-01-20"}` |
| Date is datetime | `"date:{name}:is_datetime"` key | `{"date:Due:is_datetime": "__YES__"}` |
| Reserved names (`id`, `url`) | Prefix with `"userDefined:"` | `{"userDefined:id": "PROJ-123"}` |

**Output:** Success confirmation.

---

## completions

Generate shell completion scripts for the CLI.

**Usage:**

```
better-notion completions <SHELL>
```

**Parameters:**

| Name | Required | Description |
|---|---|---|
| `SHELL` | Yes | One of: `bash`, `zsh`, `fish`, `powershell`, `elvish` |

**Output:** Shell completion script written to stdout. Redirect to a file to install:

```bash
# Zsh
better-notion completions zsh > ~/.zsh/completions/_better-notion

# Bash
better-notion completions bash > ~/.local/share/bash-completion/completions/better-notion

# Fish
better-notion completions fish > ~/.config/fish/completions/better-notion.fish
```
