# Better Notion

An alternative MCP server that wraps the official Notion MCP server to provide an LLM-friendly API for reading and updating Notion documents.

## Why?

The official Notion MCP server does not work well with LLMs, especially when it comes to document updates. Its API surface is too low-level and leads to unreliable edits.

Better Notion solves this by sitting between the LLM client and the official Notion MCP server, providing a simpler, higher-level interface.

## Architecture

```text
┌──────────────┐
│  LLM Client  │
└──────┬───────┘
       │  Better Notion MCP API
       ▼
┌──────────────┐
│ Better Notion│
└──────┬───────┘
       │  Official Notion MCP API
       ▼
┌──────────────┐
│ Notion MCP   │
└──────────────┘
```

## Tools

Better Notion exposes three MCP tools:

### `fetch_document`

Fetches a Notion document via the official Notion MCP and creates a local text representation of it. This local copy is what the LLM reads and edits.
The fetch tool will return to the LLM the path to the local version of the document. This document is stored in a temporary created directory tied with the session and will be deleted when the session ends. The LLM can read and edit this local document as needed before committing changes back to Notion.

### `commit_document`

Pushes the locally updated document back to Notion through the official MCP server, reconciling the local representation with the Notion block structure.

## How it works

1. The LLM calls `fetch_document` to retrieve a Notion page. Better Notion fetches the page via the official Notion MCP and builds a local text representation.
2. The LLM can read and edit this local document as needed.
3. When edits are complete, the LLM calls `commit_document`. Better Notion diffs the local representation against the original, translates the changes into Notion API operations, and applies them via the official MCP server.
