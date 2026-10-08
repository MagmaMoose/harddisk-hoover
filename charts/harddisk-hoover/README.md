# harddisk-hoover chart

Installs harddisk-hoover: a CronJob that frees disk space on the cluster's nodes, one
node at a time. See the [project README](https://github.com/MagmaMoose/harddisk-hoover#readme)
for what the cleanup does and the rules it keeps.

```bash
kubectl create namespace harddisk-hoover
kubectl label namespace harddisk-hoover pod-security.kubernetes.io/enforce=privileged
helm install harddisk-hoover oci://ghcr.io/magmamoose/charts/harddisk-hoover \
  --namespace harddisk-hoover --set dryRun=true
```

The cleanup pods are privileged, use the host's PID namespace and mount the host's root
filesystem, so the namespace must enforce the `privileged` Pod Security level. The
controller runs as a non-root user with a read-only root filesystem and no capabilities.

Every value is documented in [values.yaml](values.yaml) and checked by
[values.schema.json](values.schema.json).
