#!/bin/sh
set -e

/app/mcp-server --db /data --http-host "0.0.0.0:3000" &
MCP_PID=$!

/app/websocket-observer --observe --http-host "0.0.0.0:8080" --db /data &
WS_PID=$!

trap "kill $MCP_PID $WS_PID 2>/dev/null; wait" EXIT
wait
