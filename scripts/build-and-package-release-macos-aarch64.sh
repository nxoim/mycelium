#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
OUTPUT_DIR="${1:-$PROJECT_DIR/.tmp/release/macos-aarch64}"

echo "=== Building release ==="
swift build --configuration release --package-path "$PROJECT_DIR" 2>&1

echo "=== Packaging to $OUTPUT_DIR ==="
mkdir -p "$OUTPUT_DIR"

# Copy binaries
for bin in cli mcp-stdio mcp-server websocket-observer; do
    src="$PROJECT_DIR/.build/release/$bin"
    if [[ -f "$src" ]]; then
        cp "$src" "$OUTPUT_DIR/"
        echo "  ✓ $bin"
    else
        echo "  ✗ $bin not found"
        exit 1
    fi
    # Copy dSYM if present
    dsym="$PROJECT_DIR/.build/release/${bin}.dSYM"
    if [[ -d "$dsym" ]]; then
        cp -r "$dsym" "$OUTPUT_DIR/"
    fi
done

echo "=== Done ==="
echo "Release available at: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
