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

# The WAL init container needs its own privilege settings; these cannot be set
# through podSecurityContext or the main container's securityContext.
echo ""
echo "==> Validating WAL init container privilege settings..."
wal_init_security_context=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-statefulset.yaml" \
  | yq -o=json -I=0 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[] | select(.name == "create-wal-directory") | .securityContext')

if [ "$wal_init_security_context" = '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}' ]; then
  echo "  WAL init container drops capabilities and disallows privilege escalation"
else
  echo "  FAIL: WAL init container lacks required privilege settings"
  echo "  Got: $wal_init_security_context"
  exit 1
fi

echo ""
echo "==> Validating WAL PVC StorageClass selection..."
wal_pvc_storage_class() {
  helm template test-release "$CHART_DIR" -f "$1" "${@:2}" \
    | yq -r 'select(.kind == "StatefulSet") | .spec.volumeClaimTemplates[0].spec.storageClassName'
}

default_class=$(wal_pvc_storage_class "$TEST_DIR/values-statefulset.yaml")
custom_class=$(wal_pvc_storage_class "$TEST_DIR/values-statefulset-storage-class.yaml")
no_class=$(wal_pvc_storage_class "$TEST_DIR/values-statefulset.yaml" --set 'statefulSet.walPvc.storageClassName=')

if [ "$default_class" = "null" ] && [ "$custom_class" = "balanced-storage" ] && [ -z "$no_class" ]; then
  echo "  WAL PVC uses the default, specified, or disabled StorageClass as requested"
else
  echo "  FAIL: unexpected WAL PVC StorageClass (default=$default_class, custom=$custom_class, disabled=$no_class)"
  exit 1
fi

echo ""
echo "==> All tests passed!"
