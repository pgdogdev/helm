#!/bin/bash

set -e

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_PATH/.."

CHART_NAME="pgdog"
DEPLOY_DIR="$PROJECT_ROOT/deploy"

echo "Creating deploy directory..."
rm -rf "$DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"

echo "Packaging Helm chart..."
cd "$PROJECT_ROOT"
helm package . --destination "$DEPLOY_DIR"

echo "Creating/updating Helm repository index..."
helm repo index "$DEPLOY_DIR" --url "https://helm.pgdog.dev"

echo "Deployment artifacts created in $DEPLOY_DIR/"
ls -lsha "$DEPLOY_DIR/"
