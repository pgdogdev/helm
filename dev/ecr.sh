#!/bin/bash

set -eo pipefail

CHART_PACKAGE="${1:?Usage: ecr.sh <chart.tgz>}"
ECR_REGISTRY="709825985650.dkr.ecr.us-east-1.amazonaws.com"
ECR_REGION="us-east-1"

if [ -n "${ECR_AWS_ACCESS_KEY_ID:-}" ]; then
    export AWS_ACCESS_KEY_ID="$ECR_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="${ECR_AWS_SECRET_ACCESS_KEY:?Missing ECR role secret access key}"
    export AWS_SESSION_TOKEN="${ECR_AWS_SESSION_TOKEN:?Missing ECR role session token}"
fi

echo "Authenticating to AWS Marketplace ECR..."
aws ecr get-login-password --region "$ECR_REGION" | \
    helm registry login --username AWS --password-stdin "$ECR_REGISTRY"

echo "Pushing Helm chart to AWS Marketplace ECR..."
helm push "$CHART_PACKAGE" "oci://$ECR_REGISTRY/pgdog"
