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

# Validate workers: auto derives from CPU resources
echo ""
echo "==> Validating workers: auto derivation..."
workers_line() {
  helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-workers-auto.yaml" "$@" \
    | yq -r 'select(.kind == "ConfigMap" and .metadata.name == "test-release-pgdog") | .data["pgdog.toml"]' \
    | grep '^workers'
}

if workers_line | grep -Eq '= +4$'; then
  echo "  workers derived from limits.cpu (2000m -> 4)"
else
  echo "  FAIL: expected workers = 4 from limits.cpu 2000m"
  echo "  Got: $(workers_line)"
  exit 1
fi

if workers_line --set noCpuLimits=true | grep -Eq '= +3$'; then
  echo "  workers derived from requests.cpu with noCpuLimits (1500m -> 3)"
else
  echo "  FAIL: expected workers = 3 from requests.cpu 1500m with noCpuLimits"
  echo "  Got: $(workers_line --set noCpuLimits=true)"
  exit 1
fi

echo ""
echo "==> All tests passed!"
