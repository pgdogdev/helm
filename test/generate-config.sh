#!/bin/bash
set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$TEST_DIR/.."

if [ -z "$1" ]; then
  echo "Usage: $0 <values-file> [output-file]"
  echo "Example: $0 values-full.yaml pgdog.toml"
  exit 1
fi

VALUES_FILE="$1"

output=$(helm template pgdog "$CHART_DIR" -f "$VALUES_FILE" \
  | yq -r 'select(.kind == "ConfigMap" and .metadata.name == "pgdog") | .data["pgdog.toml"]')

if [ -z "$2" ]; then
  echo "$output"
else
  echo "$output" > "$2"
fi
