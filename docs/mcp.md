# Chunky search for pi and other MCP clients

Chunky exposes two tools over stdio MCP:

- `search` with `query`, `collection`, `top_k`, and `filters`
- `list_collections`

The server reads the Qdrant, embedding, and worker settings saved in the app, including the worker profile that Use last applied. API keys and the worker token come from the Keychain and are not written to logs. Search follows the Retrieval tab. It calls `POST /v1/search` on that worker when the processing host is Devbox and Devbox ingest is Qdrant Cloud. Otherwise it searches the Qdrant URL stored on the Mac. Hybrid fusion is dense plus BM25 with RRF. Rerank, Eval, and the in-app citation chat are not MCP tools.

## pi

pi loads `builtin:mcp` by default. Add the server to `~/.pi/agent/mcp.json`:

```json
{
  "mcpServers": {
    "chunky": {
      "command": "/Applications/Chunky.app/Contents/MacOS/Chunky",
      "args": ["--mcp"]
    }
  }
}
```

Use the path of the installed app. The in-app pi chat already starts with only `mcp__chunky__search` and `mcp__chunky__list_collections`, and with `bash`, `edit`, `write`, and `read` disabled.

## Other clients

Any MCP client that can spawn a stdio server can use the same command and arguments. Messages are JSON-RPC 2.0, one JSON object per line.
