#!/usr/bin/env bats
# The controller against a stand-in kubectl that records every call and answers from
# a fixed set of nodes.

setup() {
  T="$(mktemp -d)"
  export CALLS="$T/calls" STATE="$T/state"
  mkdir -p "$T/bin" "$STATE"
  : >"$CALLS"
  cat >"$T/template.yaml" <<'EOF'
kind: Pod
spec:
  nodeName: "__NODE_NAME__"
metadata:
  labels:
    run: "__RUN_ID__"
EOF
  cat >"$T/nodes.json" <<'EOF'
{"items": [
  {"metadata": {"name": "n4"}, "spec": {}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}},
  {"metadata": {"name": "n1"}, "spec": {}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}},
  {"metadata": {"name": "n2"}, "spec": {}, "status": {"conditions": [{"type": "Ready", "status": "False"}]}},
  {"metadata": {"name": "n3"}, "spec": {"unschedulable": true}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
]}
EOF
  cat >"$T/bin/kubectl" <<EOF
#!/usr/bin/env bash
[[ "\$1" == -n ]] && shift 2
echo "kubectl \$*" >>"$CALLS"
case "\$1 \$2" in
  "get nodes") cat "$T/nodes.json" ;;
  "create -f")
    node=\$(sed -n 's/.*nodeName: "\(.*\)"/\1/p')
    echo "\$node" >"$STATE/current"
    echo -n "pod-\$node"
    ;;
  "get pod")
    node=\${3#pod-}
    if [[ "\$node" == n4 ]]; then echo -n Failed; else echo -n Succeeded; fi
    ;;
  "logs pod-"*)
    node=\${2#pod-}
    echo "cleaning \$node"
    echo "HOOVER_RESULT node=\$node mode=cleaned used_before=80% used_after=60% freed_bytes=1 warnings=0 errors=0"
    ;;
  "delete pod") rm -f "$STATE/current" ;;
esac
EOF
  chmod +x "$T/bin/kubectl"
  export HOOVER_KUBECTL="$T/bin/kubectl" HOOVER_NAMESPACE=hoover HOOVER_INSTANCE=hh \
    HOOVER_POD_TEMPLATE="$T/template.yaml" HOOVER_PAUSE_SECONDS=0 HOOVER_POLL_SECONDS=0 \
    HOOVER_RUN_ID=20261008000000
}

teardown() {
  rm -rf "$T"
}

@test "cleans each Ready, schedulable node in name order, one at a time" {
  run bash /src/src/controller.sh
  # n4 fails, so the run fails.
  [ "$status" -eq 1 ]
  # Leftovers are cleared before anything else.
  head -n 1 "$CALLS" | grep -q 'delete pod -l app.kubernetes.io/instance=hh,app.kubernetes.io/component=cleanup'
  # Each node's pod is created, waited on, read and deleted before the next is created.
  grep -E '^kubectl (create|delete pod pod-)' "$CALLS" >"$T/order"
  diff -u - "$T/order" <<'EOF'
kubectl create -f - -o jsonpath={.metadata.name}
kubectl delete pod pod-n1 --ignore-not-found --wait=false
kubectl create -f - -o jsonpath={.metadata.name}
kubectl delete pod pod-n4 --ignore-not-found --wait=false
EOF
  [[ "$output" == *"n2: skipped, not Ready"* ]]
  [[ "$output" == *"n3: skipped, cordoned"* ]]
  [[ "$output" == *"n1 succeeded node=n1 mode=cleaned"* ]]
  [[ "$output" == *"n4 failed node=n4"* ]]
  [[ "$output" == *"summary: 1 node(s) done, 1 failed"* ]]
}

@test "cleans cordoned nodes when told to" {
  export HOOVER_SKIP_UNSCHEDULABLE=false
  run bash /src/src/controller.sh
  grep -q 'delete pod pod-n3' "$CALLS"
}

@test "passes the node selector through" {
  export HOOVER_NODE_SELECTOR='kubernetes.io/os=linux'
  run bash /src/src/controller.sh
  grep -q 'get nodes -o json -l kubernetes.io/os=linux' "$CALLS"
}
