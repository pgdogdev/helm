#!/bin/bash

set -eo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_PATH/.."

CHART_NAME="pgdog"
DEPLOY_DIR="$PROJECT_ROOT/deploy"
PACKAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$PACKAGE_DIR"' EXIT

echo "Creating deploy directory..."
rm -rf "$DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"

aws s3 sync s3://pgdog-helm "$DEPLOY_DIR"

echo "Packaging Helm chart..."
cd "$PROJECT_ROOT"
helm package . --destination "$PACKAGE_DIR"
cp "$PACKAGE_DIR/$CHART_NAME-"*.tgz "$DEPLOY_DIR/"

echo "Creating/updating Helm repository index..."
helm repo index "$DEPLOY_DIR" --url "https://helm.pgdog.dev"

echo "Deployment artifacts created in $DEPLOY_DIR/"
ls -lsha "$DEPLOY_DIR/"

aws s3 sync "$DEPLOY_DIR" s3://pgdog-helm

bash "$SCRIPT_PATH/ecr.sh" "$PACKAGE_DIR/$CHART_NAME-"*.tgz
