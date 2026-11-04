#!/bin/bash
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$TEST_DIR/.."

if [ -z "$1" ]; then
  echo "Usage: $0 <values-file> [output-file] [users-output-file]"
  echo "Example: $0 values-full.yaml pgdog.toml users.toml"
  exit 1
fi

VALUES_FILE="$1"

rendered=$(helm template pgdog "$CHART_DIR" -f "$VALUES_FILE")
output=$(echo "$rendered" \
  | yq -r 'select(.kind == "ConfigMap" and .metadata.name == "pgdog") | .data["pgdog.toml"]')

if [ -z "$2" ]; then
  echo "$output"
else
  echo "$output" > "$2"
fi

if [ -n "$3" ]; then
  # An absent Secret (e.g. externally managed users) produces an empty users file.
  echo "$rendered" \
    | yq -r 'select(.kind == "Secret" and .metadata.name == "pgdog") | .data["users.toml"] // ""' \
    | base64 -d > "$3"
fi
