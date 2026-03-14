# fetch_document

Fetches a Notion document and returns its content as line-numbered markdown.

## Input Schema

| Parameter | Type      | Required | Default   | Description                                      |
|-----------|-----------|----------|-----------|--------------------------------------------------|
| `page`    | `string`  | yes      | —         | Notion page URL or page UUID                     |
| `offset`  | `integer` | no       | `1`       | Line number to start reading from (1-based)      |
| `limit`   | `integer` | no       | all lines | Maximum number of lines to return                |

### Page identification

The `page` parameter accepts either:

- A raw page ID: `sample123`
- A full Notion URL: `https://www.notion.so/workspace/My-Page-sample123`

When a URL is provided, the tool extracts the page ID from the last segment of the path (everything after the final `-`).

## Output

Content is returned as markdown with line numbers, similar to `cat -n`:

```markdown
   1	# Meeting Notes - Q1 Planning
   2
   3	## Attendees
   4
   5	- Alice
   6	- Bob
   7	- Charlie
```

Line numbers are right-aligned and separated from content by a tab character.

### Pagination

When `limit` is set and the document has more lines beyond the returned range, a trailing indicator is appended:

```
   9	## Agenda
  10
  11	1. Budget review
  12	2. Hiring plan
  13	3. Product roadmap
... (36 more lines)
```

This lets the caller know there is more content to fetch with a subsequent call using a higher `offset`.

## Tool Annotations

- `read_only`: true — this tool does not modify any state
- `idempotent`: true — calling it multiple times with the same arguments produces the same result

## Static fixtures (development)

While the connection to the official Notion MCP server is not yet wired up, documents are read from static markdown files in `priv/fixtures/`. Place your files there named as `<page_id>.md`.
