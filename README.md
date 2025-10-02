# PgDog Helm Chart

Production-ready [Helm](https://helm.sh) chart for PgDog with
high availability, security, and resource management features.

## Features

✅ Resource limits with guaranteed QoS (1GB:1CPU ratio)

✅ PodDisruptionBudget for high availability

✅ Pod anti-affinity for spreading across nodes

✅ ExternalSecrets integration for secure credential management

✅ ServiceAccount and RBAC with minimal permissions

✅ Pinned image versions for production deployments

## Quick Start

1. Install Helm
2. Configure `kubectl` to point to your K8s cluster
3. Add our Helm repository:
   `helm repo add pgdogdev https://helm.pgdog.dev`
4. Configure databases and users in `values.yaml`
5. Install:
   `helm install <name> pgdogdev/pgdog -f values.yaml`

All resources will be created in `<name>` namespace.

### Configuration

Configuration is done via `values.yaml`. All PgDog settings from
`pgdog.toml` and `users.toml` are supported. General settings
(`[general]` section) are top level. Use camelCase format instead
of snake_case, for example: `checkout_timeout` becomes
`checkoutTimeout`.

#### Basic Example

```yaml
workers: 2
defaultPoolSize: 15
openMetricsPort: 9090
```

### Docker Image

Pin to a specific version for production deployments:

```yaml
image:
  repository: ghcr.io/pgdogdev/pgdog
  tag: "v1.2.3" # Pin to specific version
  pullPolicy: IfNotPresent
```

**Legacy format** (still supported for backward compatibility):

```yaml
image:
  name: ghcr.io/pgdogdev/pgdog:main
  pullPolicy: Always
```

### Databases & Users

Add databases to `databases` list:

```yaml
databases:
  - name: "prod"
    host: "10.0.0.1"
```

Add users to `users` list:

```yaml
users:
  - name: "alice"
    database: "prod"
    password: "hunter2" # See ExternalSecrets for secure storage
```

**⚠️ For production**: Use ExternalSecrets instead of plain text
passwords (see ExternalSecrets section below).

### Mirroring

Add mirrors to `mirrors` list. For example:

```yaml
mirrors:
  - sourceDb: "prod"
    destinationDb: "staging"
```

### High Availability

#### PodDisruptionBudget

Ensures minimum pod availability during voluntary disruptions
(enabled by default):

```yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 1 # At least 1 pod always available
```

#### Pod Anti-Affinity

Spreads pods across nodes for better reliability (enabled by
default):

```yaml
podAntiAffinity:
  enabled: true
  type: soft # "soft" (preferred) or "hard" (required)
```

### ExternalSecrets Integration

Securely manage credentials using ExternalSecrets operator:

**Option 1: Create ExternalSecret with chart**

```yaml
externalSecrets:
  enabled: true
  create: true
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  remoteRefs:
    - secretKey: users.toml
      remoteRef:
        key: pgdog/users
```

**Option 2: Use existing ExternalSecret**

```yaml
externalSecrets:
  enabled: true
  create: false
  name: "platform-managed-secret"
  secretName: "my-secret" # Name of Secret it creates
```

### ServiceAccount & RBAC

RBAC with minimal permissions is enabled by default:

```yaml
serviceAccount:
  create: true
  annotations: {}

rbac:
  create: true
```

### Resource Management

Default resources use Guaranteed QoS with 1GB:1CPU ratio:

```yaml
resources:
  requests:
    cpu: 1000m # 1 CPU
    memory: 1Gi # 1GB
  limits:
    cpu: 1000m
    memory: 1Gi
```

### Prometheus (optional)

Prometheus metrics can be collected with a sidecar. Enable by
configuring `prometheusPort`:

```yaml
prometheusPort: 9091

# Resources for Prometheus sidecar
prometheusResources:
  requests:
    cpu: 100m
    memory: 100Mi
  limits:
    cpu: 100m
    memory: 100Mi
```

Make sure it's different from `openMetricsPort`. You can configure
Prometheus in `templates/prom/config.yaml`.

## Contributions

Contributions are welcome. Please open a pull request / issue with
requested changes.

## License

MIT
