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

# Validate config change rollout checksums
echo ""
echo "==> Validating config change rollout checksums..."
rollout_values="$TEST_DIR/values-restart-on-config-change.yaml"
base_rendered=$(helm template test-release "$CHART_DIR" -f "$rollout_values")
config_rendered=$(helm template test-release "$CHART_DIR" -f "$rollout_values" --set logLevel=debug)
users_rendered=$(helm template test-release "$CHART_DIR" -f "$rollout_values" --set-string users[0].password=changed-password)
secret_metadata_rendered=$(helm template test-release "$CHART_DIR" -f "$rollout_values" --set-string secret.annotations.example=value)

base_config_checksum=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/config"' <<< "$base_rendered")
base_users_checksum=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/users"' <<< "$base_rendered")
changed_config_checksum=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/config"' <<< "$config_rendered")
config_change_users_checksum=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/users"' <<< "$config_rendered")
users_change_config_checksum=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/config"' <<< "$users_rendered")
changed_users_checksum=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/users"' <<< "$users_rendered")
metadata_users_checksum=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/users"' <<< "$secret_metadata_rendered")

if [[ -z "$base_config_checksum" || "$base_config_checksum" == "null" ||
      -z "$base_users_checksum" || "$base_users_checksum" == "null" ||
      -z "$changed_config_checksum" || "$changed_config_checksum" == "null" ||
      -z "$config_change_users_checksum" || "$config_change_users_checksum" == "null" ||
      -z "$users_change_config_checksum" || "$users_change_config_checksum" == "null" ||
      -z "$changed_users_checksum" || "$changed_users_checksum" == "null" ||
      -z "$metadata_users_checksum" || "$metadata_users_checksum" == "null" ]]; then
  echo "  FAIL: chart-rendered config checksums are missing"
  exit 1
fi

if [[ "$base_config_checksum" == "$changed_config_checksum" ||
      "$base_users_checksum" != "$config_change_users_checksum" ]]; then
  echo "  FAIL: pgdog.toml changes did not update only checksum/config"
  exit 1
fi

if [[ "$base_users_checksum" == "$changed_users_checksum" ||
      "$base_config_checksum" != "$users_change_config_checksum" ]]; then
  echo "  FAIL: users.toml changes did not update only checksum/users"
  exit 1
fi

if [[ "$base_users_checksum" != "$metadata_users_checksum" ]]; then
  echo "  FAIL: Secret metadata changed the users.toml checksum"
  exit 1
fi
echo "  chart-rendered config checksums update independently"

# Existing Secret contents are unavailable to Helm; retain only caller-provided
# annotations instead of emitting constant, misleading checksums.
external_rendered=$(helm template test-release "$CHART_DIR" \
  -f "$TEST_DIR/values-existing-config-secret.yaml" \
  --set restartOnConfigChange=true)
external_config_checksum=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/config"' <<< "$external_rendered")
external_users_checksum=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/users"' <<< "$external_rendered")
external_revision=$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/external-config"' <<< "$external_rendered")

if [[ "$external_config_checksum" != "null" || "$external_users_checksum" != "null" ]]; then
  echo "  FAIL: external Secrets received chart-rendered content checksums"
  exit 1
fi

if [[ "$external_revision" != "source-revision-1" ]]; then
  echo "  FAIL: external config revision pod annotation was not preserved"
  exit 1
fi
echo "  external Secrets rely on caller-provided rollout annotations"

echo ""
echo "==> All tests passed!"
