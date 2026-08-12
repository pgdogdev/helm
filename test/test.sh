#!/bin/bash
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$TEST_DIR/.."

echo "==> Linting Helm chart..."
helm lint "$CHART_DIR"

for values_file in "$TEST_DIR"/values-*.yaml; do
  name=$(basename "$values_file" .yaml | sed 's/values-//')
  echo ""
  echo "==> Templating and validating $name..."
  helm template test-release "$CHART_DIR" -f "$values_file" | kubeconform -strict -ignore-missing-schemas -summary
done

# Validate multiple passwords renders valid TOML
echo ""
echo "==> Validating multiple passwords TOML output..."
users_toml=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-multiple-passwords.yaml" \
  | yq -r 'select(.kind == "Secret" and .metadata.name == "test-release-pgdog") | .data["users.toml"]' \
  | base64 -d)

if echo "$users_toml" | grep -q 'passwords = \["one", "two"\]'; then
  echo "  passwords array rendered correctly"
else
  echo "  FAIL: passwords array not rendered correctly"
  echo "  Got: $users_toml"
  exit 1
fi

if echo "$users_toml" | grep -q 'password = "single_password"'; then
  echo "  single password rendered correctly"
else
  echo "  FAIL: single password not rendered correctly"
  echo "  Got: $users_toml"
  exit 1
fi

# Validate configSecret swaps the config volume source and skips the ConfigMap
echo ""
echo "==> Validating configSecret volume and ConfigMap suppression..."
rendered=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-existing-config-secret.yaml")

config_volume=$(echo "$rendered" \
  | yq -r 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "config") | .secret.secretName')

if [ "$config_volume" = "my-pgdog-config" ]; then
  echo "  config volume sourced from the existing Secret"
else
  echo "  FAIL: config volume not sourced from the existing Secret"
  echo "  Got: $config_volume"
  exit 1
fi

config_key=$(echo "$rendered" \
  | yq -r 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "config") | .secret.items[0] | .key + ":" + .path')

if [ "$config_key" = "my-config-key.toml:pgdog.toml" ]; then
  echo "  custom key remapped to pgdog.toml"
else
  echo "  FAIL: custom key not remapped to pgdog.toml"
  echo "  Got: $config_key"
  exit 1
fi

config_map=$(echo "$rendered" \
  | yq -r 'select(.kind == "ConfigMap" and .metadata.name == "test-release-pgdog") | .metadata.name')

if [ -z "$config_map" ]; then
  echo "  chart pgdog.toml ConfigMap not rendered"
else
  echo "  FAIL: chart pgdog.toml ConfigMap still rendered"
  exit 1
fi

echo ""
echo "==> All tests passed!"
