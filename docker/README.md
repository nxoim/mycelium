## Build

```bash
# podman or docker
podman build -f docker/Dockerfile -t localhost/mycelium:latest .
```

## Run

```bash
# podman or docker
podman run -d --name mycelium -p 3000:3000 -p 8080:8080 -v mycelium-data:/data localhost/mycelium:latest
```

### Stop and remove

```bash
# podman or docker
podman stop mycelium
podman rm mycelium
```

## MCP client

```json
{
  "mcpServers": {
    "mycelium": {
      "url": "http://localhost:3000/mcp"
    }
  }
}
```

```bash
# via curl manually
curl -s -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

## Database storage

By default the DB lives in a named volume. To keep it on the host, replace `-v mycelium-data:/data` with `-v ~/.mycelium:/data` (or any host path) in both containers.

The database file will be at `~/.mycelium/mycelium.sqlite`.

## Notes

- The MCP server will be started together with the websocket-observer by default
- MCP tool calls require `Accept: application/json` header
- Use absolute paths when overriding the CMD (`/app/mcp-server`, not `mcp-server`)
