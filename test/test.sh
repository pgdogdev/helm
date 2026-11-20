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

# Validate Vault settings render into pgdog.toml, users.toml and the env
echo ""
echo "==> Validating Vault settings..."
vault_manifests=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-vault.yaml")
vault_config=$(echo "$vault_manifests" \
  | yq -r 'select(.kind == "ConfigMap" and .metadata.name == "test-release-pgdog") | .data["pgdog.toml"]')
vault_users=$(echo "$vault_manifests" \
  | yq -r 'select(.kind == "Secret" and .metadata.name == "test-release-pgdog") | .data["users.toml"]' \
  | base64 -d)
vault_env=$(echo "$vault_manifests" \
  | yq -o=json -I=0 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "VAULT_SECRET_ID")')

for expected in \
  '[vault]' \
  'url = "https://vault.internal:8200"' \
  'auth_method = "approle"' \
  'auth_mount = "pgdog-approle"' \
  'namespace = "team-a"' \
  'approle_role_id = "4f8e2c1a-role-id"' \
  'client_token_ttl = 120'; do
  if ! echo "$vault_config" | grep -qF "$expected"; then
    echo "  FAIL: pgdog.toml is missing: $expected"
    echo "  Got: $vault_config"
    exit 1
  fi
done
echo "  [vault] section rendered correctly"

for expected in \
  'server_auth = "vault_dynamic"' \
  'server_vault_path = "database/creds/pgdog-role"' \
  'vault_refresh_percent = 75' \
  'server_auth = "vault_static"' \
  'server_vault_path = "database/static-creds/pgdog-static-role"' \
  'vault_path = "database/static-creds/pgdog-static-role"'; do
  if ! echo "$vault_users" | grep -qF "$expected"; then
    echo "  FAIL: users.toml is missing: $expected"
    echo "  Got: $vault_users"
    exit 1
  fi
done
echo "  Vault user settings rendered correctly"

if [ "$vault_env" = '{"name":"VAULT_SECRET_ID","valueFrom":{"secretKeyRef":{"name":"pgdog-vault","key":"secret-id"}}}' ]; then
  echo "  VAULT_SECRET_ID injected from the Secret"
else
  echo "  FAIL: VAULT_SECRET_ID not injected correctly"
  echo "  Got: $vault_env"
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
echo "==> Validating pod extension points..."
pod_spec() {
  helm template test-release "$CHART_DIR" -f "$@" \
    | yq -o=json -I=0 'select(.kind == "Deployment") | .spec.template.spec | {"automount": .automountServiceAccountToken, "shareProcessNamespace": .shareProcessNamespace, "containers": (.containers | map(.name)), "lifecycle": .containers[0].lifecycle}'
}
service_ports() {
  helm template test-release "$CHART_DIR" -f "$@" \
    | yq -o=json -I=0 'select(.kind == "Service" and .metadata.name == "test-release-pgdog") | .spec.ports | map(.name)'
}
expect() {
  if [ "$2" != "$3" ]; then
    echo "  FAIL: $1"
    echo "  Expected: $3"
    echo "  Got:      $2"
    exit 1
  fi
}
expect_fail() {
  if helm template test-release "$CHART_DIR" "${@:2}" >/dev/null 2>&1; then
    echo "  FAIL: rendered although $1"
    exit 1
  fi
}

expect "extension points render as set" "$(pod_spec "$TEST_DIR/values-pod-extensions.yaml")" \
  '{"automount":false,"shareProcessNamespace":true,"containers":["pgdog","reloader"],"lifecycle":{"preStop":{"exec":{"command":["/bin/sh","-c","sleep 30"]}}}}'
expect "defaults render none of them" "$(pod_spec "$TEST_DIR/values-default.yaml")" \
  '{"automount":null,"shareProcessNamespace":null,"containers":["pgdog"],"lifecycle":null}'
expect "preStopSleepSeconds still renders its preStop" "$(pod_spec "$TEST_DIR/values-default.yaml" --set preStopSleepSeconds=25 | yq -o=json -I=0 .lifecycle)" \
  '{"preStop":{"sleep":{"seconds":25}}}'
expect "automountServiceAccountToken true renders" "$(pod_spec "$TEST_DIR/values-default.yaml" --set automountServiceAccountToken=true | yq .automount)" 'true'
expect "extraContainers follow the prometheus sidecar" "$(pod_spec "$TEST_DIR/values-pod-extensions.yaml" --set prometheusPort=9091 | yq -o=json -I=0 .containers)" \
  '["pgdog","prom","reloader"]'

expect "exposeMetrics false drops the metrics port" "$(service_ports "$TEST_DIR/values-pod-extensions.yaml")" '["pgdog"]'
expect "metrics port is on the Service by default" "$(service_ports "$TEST_DIR/values-default.yaml")" '["pgdog","openmetrics"]'
# helm upgrade --reuse-values keeps the old release's values, which lack the key.
expect "missing exposeMetrics keeps the metrics port" "$(service_ports "$TEST_DIR/values-default.yaml" --set service.exposeMetrics=null)" '["pgdog","openmetrics"]'
helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-monitoring.yaml" --set service.exposeMetrics=null >/dev/null
helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-monitoring.yaml" -f "$TEST_DIR/values-statefulset.yaml" --set service.exposeMetrics=false >/dev/null

expect_fail "serviceMonitor has no Service metrics port" -f "$TEST_DIR/values-monitoring.yaml" --set service.exposeMetrics=false
expect_fail "lifecycle and preStopSleepSeconds are both set" -f "$TEST_DIR/values-pod-extensions.yaml" --set preStopSleepSeconds=25
helm template test-release "$CHART_DIR" --set-json 'lifecycle={"postStart":{"exec":{"command":["true"]}}}' >/dev/null
expect_fail "lifecycle.preStop has no explicit terminationGracePeriodSeconds" -f "$TEST_DIR/values-pod-extensions.yaml" --set terminationGracePeriodSeconds=null
echo "  lifecycle, extraContainers, shareProcessNamespace, automountServiceAccountToken and service.exposeMetrics render as set, and only when set"

echo ""
echo "==> Validating templated pull secrets and placement..."
tpl_field() {
  helm template test-release "$CHART_DIR" -f "$TEST_DIR/$1" \
    | yq -o=json -I=0 "select(.kind == \"Deployment\" and .metadata.name == \"test-release-pgdog\") | .spec.template.spec.$2"
}

tpl_pull=$(tpl_field values-tpl-placement.yaml imagePullSecrets)
tpl_node=$(tpl_field values-tpl-placement.yaml nodeSelector)
tpl_tol=$(tpl_field values-tpl-placement.yaml tolerations)
plain_pull=$(tpl_field values-default.yaml imagePullSecrets)

if [ "$tpl_pull" = '[{"name":"parent-regcred"}]' ] \
  && [ "$tpl_node" = '{"service":"pooler"}' ] \
  && [ "$tpl_tol" = '[{"effect":"NoSchedule","key":"dedicated","operator":"Equal","value":"pooler"}]' ] \
  && [ "$plain_pull" = "null" ]; then
  echo "  Templated pull secrets, nodeSelector and tolerations render from the given values"
else
  echo "  FAIL: unexpected templated fields (pull=$tpl_pull node=$tpl_node tolerations=$tpl_tol default pull=$plain_pull)"
  exit 1
fi

echo ""
echo "==> All tests passed!"
