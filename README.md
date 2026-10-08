# harddisk-hoover

Frees disk space on Kubernetes nodes, one node at a time, before the kubelet starts
evicting pods.

A node's root disk fills with things nobody cleans up in time: logs that outgrew their
rotation, containers that exited days ago, images no pod uses any more, a journal that
was never capped. When the free space drops under the kubelet's `nodefs.available`
threshold, the kubelet marks the node `DiskPressure` and starts evicting pods.
harddisk-hoover is a CronJob that sweeps the nodes and clears those out first.

It works on any node with a CRI runtime: k3s and RKE2 (`/run/k3s/containerd`), upstream
containerd, CRI-O, k0s and MicroK8s. Nothing is installed on the nodes.

## How it works

The chart installs a CronJob whose pod is the **controller**. On each run it lists the
nodes matching a label selector and, for each Ready node in name order:

1. creates one **cleanup pod**, pinned to that node with `spec.nodeName`;
2. waits for it to finish (up to a timeout), prints its log and deletes it;
3. moves on to the next node.

Only one node is ever being cleaned. The cleanup pod is privileged, shares the host's PID
namespace and mounts the host's `/` at `/host`. It runs at `system-node-critical`
priority, because the kubelet admits only critical pods to a node under `DiskPressure`,
which is exactly when the cleanup matters most.

A controller walking the nodes was chosen over a DaemonSet because a DaemonSet starts
on every node at once, has no notion of "done", and needs a separate job to collect
results. Here each node's result is in the controller's log and the Job's status, and a
failed node fails the Job.

## What the cleanup does

Each step can be turned off. In order:

| Step | What it does |
|---|---|
| `logs` | **Truncates** files in the log directories (default `/var/log`) that use more than `logMaxSize` (100M) of disk. Truncated, not deleted, so a process writing to one keeps a valid handle. Sparse files are judged by the disk they use, not their apparent size. |
| `archived-logs` | Deletes rotated and compressed logs in the log directories: `*.gz`, `*.xz`, `*.bz2`, `*.zst`, `*.N`. |
| `pod-logs` | Deletes files under `/var/log/pods` untouched for `podLogMaxAgeDays` (7). |
| `core-dumps` | Deletes `core.<pid>` files over `coreDumpMinSize` (50M) in `/var/log` and in running containers' writable layers, and empties `/var/lib/systemd/coredump`. Files written to in the last ten minutes are left alone. |
| `journal` | `journalctl --vacuum-size=<journalMaxSize>` (100M) on the host, which removes archived journal files only. |
| `package-cache` | `apt-get clean`, or `dnf`/`yum`/`zypper`'s equivalent, on the host. A busy package manager is a warning, not a failure. |
| `exited-containers` | Removes containers that exited more than `exitedContainerMinAgeHours` (24) ago, without `--force`. |
| `images` | Removes images that no container (running or exited), no pod sandbox and no pin keeps, largest first. With `imagesTargetPercent` set it stops once the node is that full or less, so the rest stay cached. |

Rules the steps keep, whatever the settings:

- No file that a process on the node holds open is deleted. The cleanup reads every
  host process's open files (that is what `hostPID` is for) and skips them.
- `/var/log` is searched whole. Any other log directory you add (k3s keeps
  `containerd.log` in `/var/lib/rancher/k3s/agent/containerd`, next to the image store)
  is searched one level deep and only for names containing `.log`, so listing a
  directory that also holds data cannot cost you the data.
- Journal files are never truncated or deleted by the file steps; a truncated journal
  file is a corrupt one. Only journald's own vacuum touches them.
- Core dumps are taken only from running containers' writable layers, read from the
  host's mount table. Files inside image layers are never touched.
- Recently exited containers keep their logs, so `kubectl logs --previous` still works
  for a recent crash.
- The pause image survives even on runtimes that do not pin it. (`crictl rmi --prune`
  counts containers only, which is why the cleanup does not use it.)

## Install

```bash
kubectl create namespace harddisk-hoover
kubectl label namespace harddisk-hoover pod-security.kubernetes.io/enforce=privileged
helm install harddisk-hoover oci://ghcr.io/magmamoose/charts/harddisk-hoover \
  --namespace harddisk-hoover --set dryRun=true
```

Start with `dryRun=true`: each node's log then says what it would truncate, delete and
remove, and nothing changes. Run a sweep without waiting for the schedule:

```bash
kubectl -n harddisk-hoover create job --from=cronjob/harddisk-hoover first-look
kubectl -n harddisk-hoover logs -f job/first-look
```

Each node ends its log with one line a script can read:

```text
HOOVER_RESULT node=worker-1 mode=cleaned used_before=81% used_after=64% freed_bytes=8214523904 warnings=0 errors=0
```

`mode` is `cleaned`, `dry-run`, `skipped` (below the threshold) or `error`.

## Configuration

The chart's [values.yaml](charts/harddisk-hoover/values.yaml) documents every value. The
ones you are most likely to set:

| Value | Default | |
|---|---|---|
| `schedule` | `17 3 * * *` | Cron schedule. |
| `timeZone` | none | Time zone for the schedule. |
| `dryRun` | `false` | Report only. |
| `threshold.percent` | `0` | Clean a node only when its `threshold.path` (`/`) is at least this full, by space or inodes. 0 cleans every node. |
| `nodes.selector` | `kubernetes.io/os=linux` | Which nodes to sweep. |
| `nodes.skipUnschedulable` | `true` | Leave cordoned nodes alone. |
| `steps.*` | all `true` | Turn steps off. |
| `limits.*` | see above | Sizes and ages the steps use. |
| `limits.imagesTargetPercent` | `0` | Stop removing images once the node is this full or less. 0 removes every unused image. |
| `criSocket` | found | The runtime socket, if it is somewhere unusual. |
| `networkPolicy.apiServer` | `0.0.0.0/0` on 443 and 6443 | Where the controller may reach the API server. |

"Full" means not available the way the kubelet's eviction signal sees it: root-reserved
blocks count as used. Pick a threshold below the kubelet's image garbage collection
threshold (`imageGCHighThresholdPercent`, 85 by default) if you want the sweep to act
before the kubelet does, and leave enough headroom for the largest burst of image
pulls your nodes see between two runs.

Every image removed is pulled again by the next pod that needs it, which counts against
registry rate limits (Docker Hub's anonymous limit is low). Set `imagesTargetPercent` a
little under the threshold so a sweep removes only as much as it needs to. On
air-gapped nodes that rely on images loaded at install time, turn the `images` step off.

The cleanup reads these environment variables, which the chart sets from the values
above: `HOOVER_DRY_RUN`, `HOOVER_THRESHOLD_PERCENT`, `HOOVER_THRESHOLD_PATH`,
`HOOVER_STEPS` (comma-separated step names), `HOOVER_LOG_DIRS`, `HOOVER_LOG_MAX_SIZE`,
`HOOVER_POD_LOG_MAX_AGE_DAYS`, `HOOVER_CORE_DUMP_MIN_SIZE`, `HOOVER_JOURNAL_MAX_SIZE`,
`HOOVER_EXITED_CONTAINER_MIN_AGE_HOURS`, `HOOVER_IMAGES_TARGET_PERCENT` and
`HOOVER_CRI_SOCKET`.

## Security

The cleanup pod has root on the node: it is privileged, in the host's PID namespace,
with the host's filesystem mounted read-write. That is what cleaning a node takes.

- Put the release in its own namespace with `pod-security.kubernetes.io/enforce=privileged`,
  and give nobody else rights to create pods there.
- The controller's service account can create pods in that namespace and list nodes,
  nothing more. Since a pod there can be privileged, treat the account like node access.
- The cleanup pods have no service account token and, with `networkPolicy.enabled`, no
  network. The controller may reach the API server only.

## Development

```bash
tests/run.sh          # unit tests (bats), inside the image
tests/e2e.sh kind     # end to end on a two-node kind cluster
tests/e2e.sh k3s      # end to end on k3s in Docker
```

The image builds with `docker buildx bake` for `linux/amd64` and `linux/arm64`. Releases
are cut on merge to `main`: the image is pushed as `ghcr.io/magmamoose/harddisk-hoover:vX.Y.Z`
and the chart as `oci://ghcr.io/magmamoose/charts/harddisk-hoover` at version `X.Y.Z`.

## License

Apache-2.0.
