# PgDog Helm Chart

[Helm](https://helm.sh) chart for PgDog.

## Usage

1. Install Helm
2. Configure `kubectl` to point to your K8s cluster
3. Add our Helm repository: `helm repo add pgdogdev https://helm.pgdog.dev`
4. Configure databases and users in `values.yaml`
5. Run `helm install <name> pgdogdev/pgdog -f values.yaml` where `<name>` is the name of your deployment.

All resources will be created in `<name>` namespace.

### Configuration

Configuration is done via `values.yaml`. All PgDog settings from `pgdog.toml` and `users.toml` are supported. General settings (`[general]` section) are top level. Use camelCase format instead of snake_case, for example: `checkout_timeout` becomes `checkoutTimeout`.

#### Example

```yaml
workers: 2
defaultPoolSize: 15
openMetricsPort: 9090
```

### Docker image

By default, the image from our GitHub repository is used. This is configurable:

```yaml
image:
  name: ghcr.io/pgdogdev/pgdog:main
  pullPolicy: Always
```

### Databases & users

Add databases to `databases` list. For example:

```yaml
databases:
  - name: "prod"
    host: "10.0.0.1"
```

Add users to `users` list, for example:

```yaml
users:
  - name: "alice"
    database: "prod"
    password: "hunter2"
```

### Prometheus (optional)

Prometheus metrics can be collected with a sidecar. Enable by configuring `prometheusPort`:

```yaml
prometheusPort: 9091
```

Make sure it's different from `openMetricsPort`. Prometheus side car will be added to all containers. You can configure Prometheus in `templates/prom/config.yaml`, e.g., to push metrics to your Grafana deployment.

## Contributions

Contributions are welcome. Please open a pull request / issue with requested changes.

## License

MIT
