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

# Validate zero values survive on the PodDisruptionBudget
echo ""
echo "==> Validating PodDisruptionBudget zero values..."

pdb_spec() {
  helm template test-release "$CHART_DIR" -f "$1" \
    | yq -r 'select(.kind == "PodDisruptionBudget") | .spec | del(.selector)'
}

min_available=$(pdb_spec "$TEST_DIR/values-pdb-min-available-zero.yaml")

if [ "$min_available" = "minAvailable: 0" ]; then
  echo "  minAvailable: 0 rendered correctly"
else
  echo "  FAIL: minAvailable: 0 not rendered correctly"
  echo "  Got: $min_available"
  exit 1
fi

max_unavailable=$(pdb_spec "$TEST_DIR/values-pdb-max-unavailable-zero.yaml")

if [ "$max_unavailable" = "maxUnavailable: 0" ]; then
  echo "  maxUnavailable: 0 rendered correctly"
else
  echo "  FAIL: maxUnavailable: 0 not rendered correctly"
  echo "  Got: $max_unavailable"
  exit 1
fi

echo ""
echo "==> All tests passed!"
