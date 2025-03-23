# PgDog Helm Chart

1. Modify `templates/config.yaml`. It contains `pgdog.toml`, directly in the template file.
2. Modify `users.toml` to add users that can connect to PgDog.
3. Run `helm install -f values.yaml pgdog ./`

## Contributions

Contributions are welcome. Please open a pull request / issue with requested changes.

## License

MIT
