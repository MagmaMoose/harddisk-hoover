#!/usr/bin/env bats
# The cleanup script against a fake node: a directory standing in for the host's root,
# a fake /proc for the open-file check, and stand-ins for crictl and nsenter that
# record how they were called. tests/run.sh runs these inside the image, so the tools
# are the ones the cleanup ships with.

setup() {
  T="$(mktemp -d)"
  H="$T/host"
  export HOOVER_HOST_ROOT="$H" HOOVER_PROC="$T/proc" HOOVER_PREFLIGHT=false NODE_NAME=test-node
  export HOOVER_CRICTL="$T/bin/crictl" HOOVER_NSENTER="$T/bin/nsenter"
  export CALLS="$T/calls" CRI_DIR="$T/cri"
  mkdir -p "$H/var/log/pods/ns_pod_uid/app" "$H/var/log/journal/0123" "$H/usr/bin" \
    "$T/proc/1/fd" "$T/proc/42/fd" "$T/bin" "$CRI_DIR"
  : >"$CALLS"

  cat >"$T/bin/nsenter" <<'EOF'
#!/usr/bin/env bash
echo "nsenter $*" >>"$CALLS"
EOF
  cat >"$T/bin/crictl" <<'EOF'
#!/usr/bin/env bash
# Drop the connection flags the script always passes.
while [[ "$1" == --runtime-endpoint || "$1" == --timeout ]]; do shift 2; done
echo "crictl $*" >>"$CALLS"
case "$*" in
  "ps -a --state exited -q") cat "$CRI_DIR/exited" 2>/dev/null ;;
  "inspect -o json "*) cat "$CRI_DIR/${4}.json" ;;
  "rm "*) exit 0 ;;
  "rmi "*) exit 0 ;;
  "images -o json") cat "$CRI_DIR/images.json" ;;
  "ps -a -o json") cat "$CRI_DIR/ps.json" ;;
  "pods --state ready -o json")
    [[ -e "$CRI_DIR/ready-fail" ]] && exit 1
    cat "$CRI_DIR/ready.json" 2>/dev/null || echo '{"items": []}'
    ;;
  "pods -q")
    [[ -e "$CRI_DIR/pods-fail" ]] && exit 1
    cat "$CRI_DIR/pods" 2>/dev/null
    ;;
  # The sandboxes that exist when one is looked up again: pods-now when a test sets it.
  "pods -q --id "*)
    now="$CRI_DIR/pods-now"
    [[ -e "$now" ]] || now="$CRI_DIR/pods"
    grep -x "$4" "$now" || true
    ;;
  "inspectp -o json "*) cat "$CRI_DIR/pod-${4}.json" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/bin/"*
  # The CRI steps look for the runtime's socket.
  mkdir -p "$H/run/containerd"
  python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
    "$H/run/containerd/containerd.sock"
}

teardown() {
  rm -rf "$T"
}

# A file that really uses <MiB> MiB of disk, not just claims the size.
mkfile() {
  mkdir -p "$(dirname "$1")"
  head -c "$(($2 * 1048576))" /dev/urandom >"$1"
}

# Make a host process hold <host path> open.
hold_open() {
  ln -s "$1" "$T/proc/42/fd/$RANDOM$RANDOM"
}

run_hoover() {
  run bash "$BATS_TEST_DIRNAME/../src/hoover.sh"
}

@test "skips a node below the threshold and touches nothing" {
  mkfile "$H/var/log/big.log" 3
  export HOOVER_THRESHOLD_PERCENT=100 HOOVER_LOG_MAX_SIZE=1M
  run_hoover
  [ "$status" -eq 0 ]
  [[ "$output" == *"below the 100% threshold"* ]]
  [[ "$output" == *"HOOVER_RESULT node=test-node mode=skipped"* ]]
  [ "$(stat -c %s "$H/var/log/big.log")" -eq 3145728 ]
}

@test "truncates oversized logs, keeps small ones, never touches the journal" {
  mkfile "$H/var/log/big.log" 3
  mkfile "$H/var/log/small.log" 0
  echo hello >"$H/var/log/small.log"
  mkfile "$H/var/log/journal/0123/system.journal" 3
  mkfile "$H/var/log/elsewhere.journal" 3
  hold_open /var/log/big.log
  export HOOVER_STEPS=logs HOOVER_LOG_MAX_SIZE=1M
  run_hoover
  [ "$status" -eq 0 ]
  [ "$(stat -c %s "$H/var/log/big.log")" -eq 0 ]
  [ "$(cat "$H/var/log/small.log")" = hello ]
  [ "$(stat -c %s "$H/var/log/journal/0123/system.journal")" -eq 3145728 ]
  [ "$(stat -c %s "$H/var/log/elsewhere.journal")" -eq 3145728 ]
  [[ "$output" == *"truncated /var/log/big.log"* ]]
}

@test "outside /var/log, touches only *.log files directly in the listed directory" {
  local d="$H/var/lib/rancher/k3s/agent/containerd"
  mkfile "$d/containerd.log" 3
  mkfile "$d/io.containerd.content.v1.content/blobs/sha256/abc" 3
  mkfile "$d/snapshots/1/fs/var/log/app.log" 3
  echo old >"$d/containerd.log.1"
  echo data >"$d/data.1"
  export HOOVER_STEPS=logs,archived-logs HOOVER_LOG_MAX_SIZE=1M \
    HOOVER_LOG_DIRS=/var/log,/var/lib/rancher/k3s/agent/containerd
  run_hoover
  [ "$status" -eq 0 ]
  [ "$(stat -c %s "$d/containerd.log")" -eq 0 ]
  [ "$(stat -c %s "$d/io.containerd.content.v1.content/blobs/sha256/abc")" -eq 3145728 ]
  [ "$(stat -c %s "$d/snapshots/1/fs/var/log/app.log")" -eq 3145728 ]
  [ ! -e "$d/containerd.log.1" ]
  [ -e "$d/data.1" ]
}

@test "leaves a sparse file alone however large it looks" {
  truncate -s 2G "$H/var/log/lastlog"
  export HOOVER_STEPS=logs HOOVER_LOG_MAX_SIZE=1M
  run_hoover
  [ "$status" -eq 0 ]
  [ "$(stat -c %s "$H/var/log/lastlog")" -eq 2147483648 ]
}

@test "removes rotated logs unless a process has them open" {
  echo a >"$H/var/log/syslog.1"
  echo b >"$H/var/log/syslog.2.gz"
  echo c >"$H/var/log/kern.log.3"
  echo d >"$H/var/log/journal/0123/system@0001.journal~"
  echo e >"$H/var/log/syslog"
  hold_open /var/log/kern.log.3
  export HOOVER_STEPS=archived-logs
  run_hoover
  [ "$status" -eq 0 ]
  [ ! -e "$H/var/log/syslog.1" ]
  [ ! -e "$H/var/log/syslog.2.gz" ]
  [ -e "$H/var/log/kern.log.3" ]
  [ -e "$H/var/log/journal/0123/system@0001.journal~" ]
  [ -e "$H/var/log/syslog" ]
  [[ "$output" == *"kept /var/log/kern.log.3: a process has it open"* ]]
}

@test "removes old pod logs, keeps recent ones and any a container still writes" {
  local d="$H/var/log/pods/ns_pod_uid/app"
  echo old >"$d/0.log"
  echo old-open >"$d/1.log"
  echo new >"$d/2.log"
  touch -d '10 days ago' "$d/0.log" "$d/1.log"
  hold_open /var/log/pods/ns_pod_uid/app/1.log
  export HOOVER_STEPS=pod-logs HOOVER_POD_LOG_MAX_AGE_DAYS=7
  run_hoover
  [ "$status" -eq 0 ]
  [ ! -e "$d/0.log" ]
  [ -e "$d/1.log" ]
  [ -e "$d/2.log" ]
}

@test "removes core dumps from writable layers only, and none still being written" {
  local upper="/var/lib/containerd/snapshots/7/fs" image_layer="/var/lib/containerd/snapshots/3/fs"
  mkfile "$H$upper/app/core.1234" 2
  mkfile "$H$upper/app/core.5678" 2
  mkfile "$H$upper/app/core.data" 2
  mkfile "$H$image_layer/core.4321" 2
  mkfile "$H/var/lib/systemd/coredump/core.app.0.abc.123.zst" 1
  touch -d '1 hour ago' "$H$upper/app/core.1234" "$H$upper/app/core.data" "$H$image_layer/core.4321" \
    "$H/var/lib/systemd/coredump/core.app.0.abc.123.zst"
  cat >"$T/proc/1/mountinfo" <<EOF
22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw
900 22 0:50 / /run/containerd/rootfs rw,relatime - overlay overlay rw,lowerdir=$image_layer,upperdir=$upper,workdir=/var/lib/containerd/snapshots/7/work
EOF
  export HOOVER_STEPS=core-dumps HOOVER_CORE_DUMP_MIN_SIZE=1M
  run_hoover
  [ "$status" -eq 0 ]
  [ ! -e "$H$upper/app/core.1234" ]
  [ -e "$H$upper/app/core.5678" ]
  [ -e "$H$upper/app/core.data" ]
  [ -e "$H$image_layer/core.4321" ]
  [ ! -e "$H/var/lib/systemd/coredump/core.app.0.abc.123.zst" ]
}

@test "vacuums the journal and cleans the package cache through the host's tools" {
  touch "$H/usr/bin/journalctl" "$H/usr/bin/apt-get"
  chmod +x "$H/usr/bin/journalctl" "$H/usr/bin/apt-get"
  export HOOVER_STEPS=journal,package-cache HOOVER_JOURNAL_MAX_SIZE=64M
  run_hoover
  [ "$status" -eq 0 ]
  grep -qx 'nsenter journalctl --vacuum-size=64M' "$CALLS"
  grep -qx 'nsenter apt-get clean' "$CALLS"
}

@test "skips the journal on a node without journald" {
  export HOOVER_STEPS=journal
  run_hoover
  [ "$status" -eq 0 ]
  [[ "$output" == *"no journalctl on this node"* ]]
  ! grep -q nsenter "$CALLS"
}

# exited_container <name> <finishedAt> <sandbox id> <pod uid>: writes c-<name>.json as
# `crictl inspect` reports it.
exited_container() {
  printf '{"status":{"finishedAt":"%s","metadata":{"name":"app"},"labels":{"io.kubernetes.pod.namespace":"ns","io.kubernetes.pod.name":"p","io.kubernetes.pod.uid":"%s"}},"info":{"sandboxID":"%s"}}' \
    "$2" "$4" "$3" >"$CRI_DIR/c-$1.json"
}

@test "removes only containers that exited more than the minimum age ago" {
  local old new never
  old=$(date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%S.000000000Z)
  new=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%S.000000000Z)
  printf '%s\n' c-old c-new c-never c-bad >"$CRI_DIR/exited"
  for c in old new; do
    v=$old
    [ "$c" = new ] && v=$new
    exited_container "$c" "$v" "s-$c" "u-$c"
  done
  echo '{"status":{"finishedAt":"0001-01-01T00:00:00Z"}}' >"$CRI_DIR/c-never.json"
  echo '{"status":{"finishedAt":"yesterday-ish"}}' >"$CRI_DIR/c-bad.json"
  export HOOVER_STEPS=exited-containers HOOVER_EXITED_CONTAINER_MIN_AGE_HOURS=24
  run_hoover
  [ "$status" -eq 0 ]
  grep -qx 'crictl rm c-old' "$CALLS"
  ! grep -q 'crictl rm c-new' "$CALLS"
  ! grep -q 'crictl rm c-never' "$CALLS"
  ! grep -q 'crictl rm c-bad' "$CALLS"
  ! grep -q -- '--force\|-f ' "$CALLS"
  [[ "$output" == *"removed 1 container(s), kept 3, and 0 of running pods"* ]]
}

@test "keeps the exited containers of a pod that is still running" {
  local old
  old=$(date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%S.000000000Z)
  echo '{"items": [{"id": "s-run", "metadata": {"name": "web", "uid": "u-run"}}]}' >"$CRI_DIR/ready.json"
  printf '%s\n' c-init c-prev c-gone c-unknown >"$CRI_DIR/exited"
  # An init container in the running sandbox, and one from the same pod's earlier sandbox.
  exited_container init "$old" s-run u-run
  exited_container prev "$old" s-before u-run
  exited_container gone "$old" s-gone u-gone
  # No sandbox and no pod UID: which pod it belongs to cannot be told.
  printf '{"status":{"finishedAt":"%s"}}' "$old" >"$CRI_DIR/c-unknown.json"
  export HOOVER_STEPS=exited-containers HOOVER_EXITED_CONTAINER_MIN_AGE_HOURS=24
  run_hoover
  [ "$status" -eq 0 ]
  grep -qx 'crictl rm c-gone' "$CALLS"
  [ "$(grep -c '^crictl rm ' "$CALLS")" -eq 1 ]
  [[ "$output" == *"removed 1 container(s), kept 1, and 2 of running pods"* ]]
}

@test "removes no container when the running pods cannot be listed" {
  printf '%s\n' c-old >"$CRI_DIR/exited"
  exited_container old "$(date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%SZ)" s-old u-old
  touch "$CRI_DIR/ready-fail"
  export HOOVER_STEPS=exited-containers
  run_hoover
  [ "$status" -eq 1 ]
  ! grep -q '^crictl rm ' "$CALLS"
  [[ "$output" == *"could not list the running pods, so no container is removed"* ]]
  [[ "$output" == *"errors=1"* ]]
}

# What the runtime reports in the image tests: one image a container uses, one a pod
# sandbox uses (named without its registry, as kubelets often configure it), one pinned
# and one that nothing uses.
image_fixtures() {
  cat >"$CRI_DIR/images.json" <<'EOF'
{"images": [
  {"id": "sha256:aaa", "repoTags": ["docker.io/library/used:1"], "size": "10"},
  {"id": "sha256:bbb", "repoTags": ["docker.io/library/unused:1"], "size": "2048"},
  {"id": "sha256:ccc", "repoTags": ["docker.io/rancher/mirrored-pause:3.6"], "size": "5"},
  {"id": "sha256:ddd", "repoTags": ["registry.k8s.io/pinned:1"], "size": "7", "pinned": true}
]}
EOF
  echo '{"containers": [{"imageRef": "sha256:aaa", "image": {"image": "sha256:aaa"}}]}' >"$CRI_DIR/ps.json"
  echo p1 >"$CRI_DIR/pods"
  echo '{"info": {"image": "rancher/mirrored-pause:3.6"}}' >"$CRI_DIR/pod-p1.json"
}

@test "removes only images no container, sandbox or pin keeps" {
  image_fixtures
  export HOOVER_STEPS=images
  run_hoover
  [ "$status" -eq 0 ]
  grep -qx 'crictl rmi sha256:bbb' "$CALLS"
  [ "$(grep -c '^crictl rmi ' "$CALLS")" -eq 1 ]
  [[ "$output" == *"removed docker.io/library/unused:1 (2.0KB)"* ]]
  [[ "$output" == *"removed 1 image(s)"* ]]
}

@test "handles a container list larger than one command-line argument may be" {
  image_fixtures
  # 3000 exited containers: about 300 KiB of JSON, over the 128 KiB per-argument limit.
  python3 - "$CRI_DIR/ps.json" <<'PY'
import json, sys
cs = [{"imageRef": "sha256:aaa", "image": {"image": "sha256:aaa"}, "id": "c%05d" % i,
       "metadata": {"name": "container-with-a-fairly-long-name-%05d" % i}} for i in range(3000)]
json.dump({"containers": cs}, open(sys.argv[1], "w"))
PY
  [ "$(stat -c %s "$CRI_DIR/ps.json")" -gt 131072 ]
  export HOOVER_STEPS=images
  run_hoover
  [ "$status" -eq 0 ]
  grep -qx 'crictl rmi sha256:bbb' "$CALLS"
  [ "$(grep -c '^crictl rmi ' "$CALLS")" -eq 1 ]
  [[ "$output" != *"Argument list too long"* ]]
}

@test "removes the largest unused image first" {
  image_fixtures
  cat >"$CRI_DIR/images.json" <<'EOF'
{"images": [
  {"id": "sha256:small", "repoTags": ["docker.io/library/small:1"], "size": "100"},
  {"id": "sha256:big", "repoTags": ["docker.io/library/big:1"], "size": "900000"},
  {"id": "sha256:mid", "repoTags": ["docker.io/library/mid:1"], "size": "5000"}
]}
EOF
  export HOOVER_STEPS=images
  run_hoover
  [ "$status" -eq 0 ]
  [ "$(grep '^crictl rmi ' "$CALLS" | tr '\n' ' ')" = "crictl rmi sha256:big crictl rmi sha256:mid crictl rmi sha256:small " ]
}

@test "removes no image when the pod sandboxes cannot be listed" {
  image_fixtures
  touch "$CRI_DIR/pods-fail"
  export HOOVER_STEPS=images
  run_hoover
  [ "$status" -eq 1 ]
  ! grep -q '^crictl rmi ' "$CALLS"
  [[ "$output" == *"could not list the pod sandboxes"* ]]
  [[ "$output" == *"so no image is removed"* ]]
}

@test "removes no image when a sandbox that still exists cannot be inspected" {
  image_fixtures
  echo p2 >>"$CRI_DIR/pods"
  export HOOVER_STEPS=images
  run_hoover
  [ "$status" -eq 1 ]
  ! grep -q '^crictl rmi ' "$CALLS"
  [[ "$output" == *"could not inspect pod sandbox p2"* ]]
}

@test "skips a sandbox that is gone by the time it is inspected" {
  image_fixtures
  echo p2 >>"$CRI_DIR/pods"
  echo p1 >"$CRI_DIR/pods-now"
  export HOOVER_STEPS=images
  run_hoover
  [ "$status" -eq 0 ]
  grep -qx 'crictl rmi sha256:bbb' "$CALLS"
  [ "$(grep -c '^crictl rmi ' "$CALLS")" -eq 1 ]
}

@test "removes no image when a running sandbox does not name its image" {
  image_fixtures
  echo '{"status": {"state": "SANDBOX_READY"}, "info": {}}' >"$CRI_DIR/pod-p1.json"
  export HOOVER_STEPS=images
  run_hoover
  [ "$status" -eq 1 ]
  ! grep -q '^crictl rmi ' "$CALLS"
  [[ "$output" == *"pod sandbox p1 (SANDBOX_READY) does not name its image"* ]]
}

@test "skips a stopped sandbox that names no image" {
  image_fixtures
  echo p2 >>"$CRI_DIR/pods"
  echo '{"status": {"state": "SANDBOX_NOTREADY"}, "info": {}}' >"$CRI_DIR/pod-p2.json"
  export HOOVER_STEPS=images
  run_hoover
  [ "$status" -eq 0 ]
  grep -qx 'crictl rmi sha256:bbb' "$CALLS"
  [ "$(grep -c '^crictl rmi ' "$CALLS")" -eq 1 ]
}

@test "removes no image when no sandbox names one" {
  image_fixtures
  : >"$CRI_DIR/pods"
  export HOOVER_STEPS=images
  run_hoover
  [ "$status" -eq 1 ]
  ! grep -q '^crictl rmi ' "$CALLS"
  [[ "$output" == *"no pod sandbox named its image"* ]]
}

@test "stops removing images once the node is under the image target" {
  image_fixtures
  # Any real filesystem is under 100% used, so nothing needs to go.
  export HOOVER_STEPS=images HOOVER_IMAGES_TARGET_PERCENT=100
  run_hoover
  [ "$status" -eq 0 ]
  ! grep -q '^crictl rmi ' "$CALLS"
  [[ "$output" == *"removed 0 image(s)"*"kept 1 unused"* ]]
}

@test "dry run changes nothing and says what it would do" {
  mkfile "$H/var/log/big.log" 3
  echo a >"$H/var/log/syslog.1"
  echo c1 >"$CRI_DIR/exited"
  exited_container 1 "$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)" s-1 u-1
  mv "$CRI_DIR/c-1.json" "$CRI_DIR/c1.json"
  image_fixtures
  touch "$H/usr/bin/journalctl"
  chmod +x "$H/usr/bin/journalctl"
  export HOOVER_DRY_RUN=true HOOVER_LOG_MAX_SIZE=1M
  run_hoover
  [ "$status" -eq 0 ]
  [ "$(stat -c %s "$H/var/log/big.log")" -eq 3145728 ]
  [ -e "$H/var/log/syslog.1" ]
  ! grep -q 'crictl rm \|crictl rmi\|vacuum' "$CALLS"
  [[ "$output" == *"would truncate /var/log/big.log"* ]]
  [[ "$output" == *"would delete /var/log/syslog.1"* ]]
  [[ "$output" == *"would remove c1"* ]]
  [[ "$output" == *"would remove docker.io/library/unused:1"* ]]
  [[ "$output" != *"would remove docker.io/library/used:1"* ]]
  [[ "$output" != *"would remove docker.io/rancher/mirrored-pause"* ]]
  [[ "$output" != *"would remove registry.k8s.io/pinned"* ]]
  [[ "$output" == *"mode=dry-run"* ]]
}

@test "turns off the container steps when there is no runtime socket" {
  rm "$H/run/containerd/containerd.sock"
  export HOOVER_STEPS=exited-containers,images
  run_hoover
  [ "$status" -eq 0 ]
  [[ "$output" == *"no container runtime socket found"* ]]
  [ ! -s "$CALLS" ]
}

@test "fails loudly without the host's root filesystem" {
  export HOOVER_HOST_ROOT="$T/nowhere"
  run_hoover
  [ "$status" -eq 2 ]
  [[ "$output" == *"mode=error"* ]]
}

@test "refuses to run outside the host's PID namespace" {
  export HOOVER_PREFLIGHT=true
  run_hoover
  [ "$status" -eq 2 ]
  [[ "$output" == *"PID 1 is not the host's init"* ]]
}
