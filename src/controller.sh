#!/usr/bin/env bash
# harddisk-hoover controller: run the cleanup on each node, one node at a time.
#
# Runs as the CronJob's pod. For every Ready node that matches the selector it creates
# one cleanup pod from the template the chart renders, pinned to that node with
# spec.nodeName, waits for it to finish, prints its log and deletes it, then moves on.
# Only one node is ever being cleaned, so a misbehaving cleanup cannot take more than
# one node's I/O at a time.
#
# Exits 1 when any node's cleanup failed or timed out, so the Job shows the failure.

set -euo pipefail

NAMESPACE="${HOOVER_NAMESPACE:?HOOVER_NAMESPACE is required}"
INSTANCE="${HOOVER_INSTANCE:?HOOVER_INSTANCE is required}"
TEMPLATE="${HOOVER_POD_TEMPLATE:-/etc/harddisk-hoover/cleanup-pod.yaml}"
NODE_SELECTOR="${HOOVER_NODE_SELECTOR:-}"
SKIP_UNSCHEDULABLE="${HOOVER_SKIP_UNSCHEDULABLE:-true}"
POD_TIMEOUT="${HOOVER_POD_TIMEOUT_SECONDS:-900}"
PAUSE="${HOOVER_PAUSE_SECONDS:-5}"
POLL="${HOOVER_POLL_SECONDS:-5}"
KEEP_PODS="${HOOVER_KEEP_PODS:-false}"
RUN_ID="${HOOVER_RUN_ID:-$(date -u +%Y%m%d%H%M%S)}"
KUBECTL="${HOOVER_KUBECTL:-kubectl}"

CLEANUP_SELECTOR="app.kubernetes.io/instance=${INSTANCE},app.kubernetes.io/component=cleanup"
CURRENT_POD=""

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

is_true() {
  case "${1,,}" in
    true | 1 | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

k() { "$KUBECTL" -n "$NAMESPACE" "$@"; }

# The Job's deadline or a deleted Job sends SIGTERM: take the node's pod with us
# rather than leave a cleanup running that nothing is watching.
on_term() {
  if [[ -n "$CURRENT_POD" ]]; then
    log "stopping: deleting $CURRENT_POD"
    k delete pod "$CURRENT_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  exit 143
}
trap on_term TERM INT

# "<name> <Ready status> <unschedulable>" per node, sorted by name.
list_nodes() {
  local args=(get nodes -o json)
  [[ -n "$NODE_SELECTOR" ]] && args+=(-l "$NODE_SELECTOR")
  "$KUBECTL" "${args[@]}" | jq -r '
    .items | sort_by(.metadata.name)[]
    | [ .metadata.name,
        ((.status.conditions // [] | map(select(.type == "Ready"))[0].status) // "Unknown"),
        (.spec.unschedulable // false | tostring) ]
    | @tsv'
}

render_pod() {
  local node=$1
  # Node names are DNS subdomains, but the template is YAML, so say so out loud
  # before substituting one into it.
  if [[ ! "$node" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
    log "refusing node name '$node': not a DNS subdomain"
    return 1
  fi
  sed -e "s/__NODE_NAME__/${node}/g" -e "s/__RUN_ID__/${RUN_ID}/g" "$TEMPLATE"
}

# Wait for the pod to finish. Prints the final phase, or "Timeout".
wait_for_pod() {
  local pod=$1 deadline phase
  deadline=$((SECONDS + POD_TIMEOUT))
  while ((SECONDS < deadline)); do
    phase=$(k get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$phase" in
      Succeeded | Failed)
        echo "$phase"
        return
        ;;
    esac
    sleep "$POLL"
  done
  echo Timeout
}

clean_node() {
  local node=$1 manifest pod phase logs result reason
  if ! manifest=$(render_pod "$node"); then
    SUMMARY+=("$node failed (bad node name)")
    return 1
  fi
  if ! pod=$(k create -f - -o jsonpath='{.metadata.name}' <<<"$manifest"); then
    log "$node: could not create the cleanup pod"
    SUMMARY+=("$node failed (pod not created)")
    return 1
  fi
  CURRENT_POD=$pod
  log "$node: cleaning with pod $pod"
  phase=$(wait_for_pod "$pod")
  logs=$(k logs "$pod" -c hoover 2>&1 || true)
  if [[ -n "$logs" ]]; then
    printf '%s\n' "$logs" | sed "s/^/  | /"
  fi
  if [[ "$phase" != Succeeded ]]; then
    reason=$(k get pod "$pod" -o jsonpath='{.status.reason} {.status.message} {.status.containerStatuses[0].state.waiting.reason} {.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
    log "$node: $phase ${reason}"
  fi
  if is_true "$KEEP_PODS" && [[ "$phase" != Timeout ]]; then
    log "$node: keeping $pod"
  else
    k delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || log "$node: could not delete $pod"
  fi
  CURRENT_POD=""
  result=$(grep -o 'HOOVER_RESULT .*' <<<"$logs" | tail -n 1 || true)
  SUMMARY+=("$node ${phase,,} ${result#HOOVER_RESULT }")
  [[ "$phase" == Succeeded ]]
}

main() {
  local name ready unschedulable failed=0 cleaned=0 first=true
  SUMMARY=()
  [[ -r "$TEMPLATE" ]] || {
    log "no pod template at $TEMPLATE"
    exit 2
  }
  log "harddisk-hoover run $RUN_ID in namespace $NAMESPACE"

  # A controller killed mid-run (node drain, deadline) can leave its cleanup pod
  # behind. Remove those first, so this run is the only one on any node.
  k delete pod -l "$CLEANUP_SELECTOR" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 ||
    log "could not remove leftover cleanup pods"

  local nodes
  nodes=$(list_nodes)
  if [[ -z "$nodes" ]]; then
    log "no nodes match '${NODE_SELECTOR}'"
    exit 0
  fi
  while IFS=$'\t' read -r name ready unschedulable; do
    if [[ "$ready" != True ]]; then
      log "$name: skipped, not Ready"
      SUMMARY+=("$name skipped (not Ready)")
      continue
    fi
    if [[ "$unschedulable" == true ]] && is_true "$SKIP_UNSCHEDULABLE"; then
      log "$name: skipped, cordoned"
      SUMMARY+=("$name skipped (cordoned)")
      continue
    fi
    if [[ "$first" == true ]]; then
      first=false
    elif ((PAUSE > 0)); then
      sleep "$PAUSE"
    fi
    if clean_node "$name"; then
      cleaned=$((cleaned + 1))
    else
      failed=$((failed + 1))
    fi
  done <<<"$nodes"

  log "summary: $cleaned node(s) done, $failed failed"
  printf '  %s\n' "${SUMMARY[@]}"
  ((failed == 0))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
