#!/usr/bin/env bash
# End-to-end: install the chart on a throwaway cluster, run a dry-run sweep and then a
# real one, and check what each did to the nodes.
#
#   tests/e2e.sh kind  [image]   # kind: two nodes, upstream containerd
#   tests/e2e.sh k3s   [image]   # k3s in Docker: k3s's own containerd socket
#
# The image defaults to a fresh local build. Needs docker, helm, kubectl and jq (and
# kind for the kind flavour). Leaves nothing behind unless KEEP=1.
set -euo pipefail

flavour="${1:?usage: tests/e2e.sh kind|k3s [image]}"
image="${2:-}"
cd "$(dirname "$0")/.."

NAME=hoover-e2e
NS=harddisk-hoover
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.34.6-k3s1}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"
WORK="$(mktemp -d)"
export KUBECONFIG="$WORK/kubeconfig"

log() { printf '\n=== %s\n' "$*"; }

crictl_on() { docker exec "$1" crictl "${@:2}"; }

# has_image <node> <ref>: the node's runtime has an image tagged <ref>. (`crictl images
# -q <ref>` is no use here: it lists every image whatever the filter.)
has_image() {
  crictl_on "$1" images -o json | jq -e --arg r "$2" 'any(.images[]; (.repoTags // []) | index($r))' >/dev/null
}

cleanup() {
  if [[ "${KEEP:-0}" == 1 ]]; then
    echo "KEEP=1: leaving the $flavour cluster up (KUBECONFIG=$KUBECONFIG)"
    return
  fi
  case "$flavour" in
    kind) kind delete cluster --name "$NAME" >/dev/null 2>&1 || true ;;
    k3s) docker rm -f "$NAME" >/dev/null 2>&1 || true ;;
  esac
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -z "$image" ]]; then
  image=harddisk-hoover:e2e
  log "building $image"
  docker build -q -t "$image" . >/dev/null
fi

# node_exec <node> <command...>: run a command on a node (a container either way).
nodes=()
case "$flavour" in
  kind)
    log "creating a two-node kind cluster"
    cat >"$WORK/kind.yaml" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
EOF
    kind create cluster --name "$NAME" --config "$WORK/kind.yaml" --wait 120s \
      ${KIND_NODE_IMAGE:+--image "$KIND_NODE_IMAGE"} --kubeconfig "$KUBECONFIG" >/dev/null
    kind load docker-image "$image" --name "$NAME" >/dev/null
    nodes=("$NAME-control-plane" "$NAME-worker")
    ;;
  k3s)
    log "starting k3s ($K3S_IMAGE) in Docker"
    # The test cluster's API server, on a random loopback port.
    api_port_mapping="127.0.0.1::6443" # DevSkim: ignore DS162092
    docker run -d --name "$NAME" --hostname "$NAME" --privileged --tmpfs /run --tmpfs /var/run \
      -e K3S_KUBECONFIG_OUTPUT=/output/kubeconfig -e K3S_KUBECONFIG_MODE=644 \
      -v "$WORK:/output" -p "$api_port_mapping" \
      "$K3S_IMAGE" server --disable=traefik,metrics-server,servicelb >/dev/null
    for _ in $(seq 60); do [[ -s "$WORK/kubeconfig" ]] && break; sleep 2; done
    port=$(docker port "$NAME" 6443/tcp | head -n 1 | sed 's/.*://')
    sed -i.bak "s#https://127.0.0.1:6443#https://127.0.0.1:${port}#" "$KUBECONFIG" # DevSkim: ignore DS162092
    for _ in $(seq 60); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 2; done
    docker save "$image" | docker exec -i "$NAME" ctr -n k8s.io images import - >/dev/null
    nodes=("$NAME")
    ;;
  *)
    echo "unknown flavour: $flavour" >&2
    exit 2
    ;;
esac
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
kubectl get nodes -o wide

log "installing the chart (dry run)"
kubectl create namespace "$NS" >/dev/null
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged >/dev/null
repo="${image%:*}"
tag="${image##*:}"
helm_args=(
  --namespace "$NS" --wait
  --set image.repository="$repo" --set image.tag="$tag" --set image.pullPolicy=Never
  --set schedule="0 0 1 1 *" --set nodes.pauseSeconds=1
)
helm upgrade --install hoover charts/harddisk-hoover "${helm_args[@]}" --set dryRun=true >/dev/null

# sweep <job>: run the CronJob once and print the controller's log.
sweep() {
  kubectl -n "$NS" create job --from=cronjob/hoover-harddisk-hoover "$1" >/dev/null
  if ! kubectl -n "$NS" wait --for=condition=Complete "job/$1" --timeout=600s >/dev/null; then
    kubectl -n "$NS" logs "job/$1" || true
    kubectl -n "$NS" get pods -o wide || true
    echo "FAIL: sweep $1 did not complete" >&2
    exit 1
  fi
  kubectl -n "$NS" logs "job/$1" | tee "$WORK/$1.log"
}

# Something for each step to find, on every node.
for node in "${nodes[@]}"; do
  docker exec "$node" sh -c '
    head -c 120000000 /dev/urandom > /var/log/hoover-e2e-big.log
    echo old > /var/log/hoover-e2e.log.1
    echo old > /var/log/hoover-e2e.log.2.gz'
  crictl_on "$node" pull docker.io/library/busybox:1.37.0 >/dev/null
done

log "dry-run sweep"
sweep dry-run
for node in "${nodes[@]}"; do
  grep -q "HOOVER_RESULT node=$node mode=dry-run" "$WORK/dry-run.log" || {
    echo "FAIL: no dry-run result for $node" >&2
    exit 1
  }
  [[ "$(docker exec "$node" stat -c %s /var/log/hoover-e2e-big.log)" == 120000000 ]] || {
    echo "FAIL: the dry run truncated a log on $node" >&2
    exit 1
  }
  has_image "$node" docker.io/library/busybox:1.37.0 || {
    echo "FAIL: the dry run pruned an image on $node" >&2
    exit 1
  }
done
grep -q 'would truncate /var/log/hoover-e2e-big.log' "$WORK/dry-run.log"
grep -q 'would remove docker.io/library/busybox:1.37.0' "$WORK/dry-run.log"

log "real sweep"
helm upgrade hoover charts/harddisk-hoover "${helm_args[@]}" --set dryRun=false >/dev/null
sweep real
for node in "${nodes[@]}"; do
  grep -q "HOOVER_RESULT node=$node mode=cleaned" "$WORK/real.log" || {
    echo "FAIL: no clean result for $node" >&2
    exit 1
  }
  [[ "$(docker exec "$node" stat -c %s /var/log/hoover-e2e-big.log)" == 0 ]] || {
    echo "FAIL: the big log on $node was not truncated" >&2
    exit 1
  }
  if docker exec "$node" test -e /var/log/hoover-e2e.log.1; then
    echo "FAIL: a rotated log on $node was not removed" >&2
    exit 1
  fi
  if has_image "$node" docker.io/library/busybox:1.37.0; then
    echo "FAIL: the unused image on $node was not pruned" >&2
    exit 1
  fi
  # Every running pod's sandbox (pause) image must survive, pinned or not.
  for ref in $(crictl_on "$node" pods -q | xargs -n 1 docker exec "$node" crictl inspectp -o json |
    jq -r '.info.image // empty' | sort -u); do
    has_image "$node" "$ref" || has_image "$node" "docker.io/$ref" || {
      echo "FAIL: the sandbox image $ref was removed from $node" >&2
      exit 1
    }
  done
done

log "threshold: a 100% threshold skips every node"
helm upgrade hoover charts/harddisk-hoover "${helm_args[@]}" --set threshold.percent=100 >/dev/null
sweep threshold
skipped=$(grep -c '^  | HOOVER_RESULT .*mode=skipped' "$WORK/threshold.log" || true)
[[ "$skipped" == "${#nodes[@]}" ]] || {
  echo "FAIL: $skipped of ${#nodes[@]} node(s) skipped at a 100% threshold" >&2
  exit 1
}

leftover=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=cleanup -o name)
[[ -z "$leftover" ]] || {
  echo "FAIL: cleanup pods left behind: $leftover" >&2
  exit 1
}
log "PASS ($flavour)"
