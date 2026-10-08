#!/usr/bin/env bash
# harddisk-hoover: free disk space on the node this pod runs on.
#
# Runs in a privileged pod with the host's root filesystem mounted at HOOVER_HOST_ROOT
# and the host's PID namespace (hostPID), one node at a time (the controller makes sure
# of that). Every step is best-effort: a step that fails is reported and the next one
# still runs.
#
# Safety rules, in the order the steps run:
#   - Oversized logs are TRUNCATED, never deleted, so a process writing to one keeps a
#     valid file handle. Journal files are never touched by the file steps.
#   - No file that any process on the host holds open is deleted.
#   - Only containers that EXITED more than HOOVER_EXITED_CONTAINER_MIN_AGE_HOURS ago, of
#     pods that are gone (their sandbox is no longer Ready), are removed, and without
#     --force, so a running container is refused by the runtime. A running pod keeps its
#     init containers' records, and recent crashes keep their logs for
#     `kubectl logs --previous`.
#   - Images are removed only when no container, running or exited, and no pod sandbox
#     uses them. Pinned images are never removed. When the runtime cannot say which
#     images its sandboxes use, no image is removed.
#   - The journal is vacuumed by journald's own tool, which only removes archived files.
#
# Settings are environment variables; see the README for the full list.

set -uo pipefail

HOST="${HOOVER_HOST_ROOT:-/host}"
PROC="${HOOVER_PROC:-/proc}"
DRY_RUN="${HOOVER_DRY_RUN:-false}"
THRESHOLD="${HOOVER_THRESHOLD_PERCENT:-0}"
THRESHOLD_PATH="${HOOVER_THRESHOLD_PATH:-/}"
STEPS="${HOOVER_STEPS:-logs,archived-logs,pod-logs,core-dumps,journal,package-cache,exited-containers,images}"
LOG_DIRS="${HOOVER_LOG_DIRS:-/var/log}"
LOG_MAX_SIZE="${HOOVER_LOG_MAX_SIZE:-100M}"
POD_LOG_MAX_AGE_DAYS="${HOOVER_POD_LOG_MAX_AGE_DAYS:-7}"
CORE_DUMP_MIN_SIZE="${HOOVER_CORE_DUMP_MIN_SIZE:-50M}"
JOURNAL_MAX_SIZE="${HOOVER_JOURNAL_MAX_SIZE:-100M}"
CONTAINER_MIN_AGE_HOURS="${HOOVER_EXITED_CONTAINER_MIN_AGE_HOURS:-24}"
IMAGES_TARGET="${HOOVER_IMAGES_TARGET_PERCENT:-0}"
CRI_SOCKET="${HOOVER_CRI_SOCKET:-}"
PREFLIGHT="${HOOVER_PREFLIGHT:-true}"
NODE="${NODE_NAME:-$(hostname)}"
# Overridable so the tests can stand in for the host's tools.
CRICTL="${HOOVER_CRICTL:-crictl}"
read -r -a NSENTER <<<"${HOOVER_NSENTER:-nsenter --target 1 --mount --}"

# Where the container runtime may listen, most specific first. k3s and RKE2 share the
# first path; the rest are upstream containerd, CRI-O, k0s and MicroK8s.
CRI_SOCKET_CANDIDATES=(
  /run/k3s/containerd/containerd.sock
  /run/containerd/containerd.sock
  /var/run/containerd/containerd.sock
  /run/crio/crio.sock
  /var/run/crio/crio.sock
  /run/k0s/containerd.sock
  /var/snap/microk8s/common/run/containerd.sock
)

# Lines of per-file detail printed per step before it is summarised.
DETAIL_LIMIT="${HOOVER_DETAIL_LIMIT:-200}"

WARNINGS=0
ERRORS=0
STEP_COUNT=0
STEP_BYTES=0
SCOPE_DEPTH=()
SCOPE_NAME=()
declare -A OPEN_FILES=()

log() { printf '%s [%s] %s\n' "$(date -u +%H:%M:%SZ)" "$NODE" "$*"; }
warn() { log "WARN: $*"; WARNINGS=$((WARNINGS + 1)); }
error() { log "ERROR: $*"; ERRORS=$((ERRORS + 1)); }

is_true() {
  case "${1,,}" in
    true | 1 | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

dry_run() { is_true "$DRY_RUN"; }

step_enabled() { [[ ",${STEPS// /}," == *",$1,"* ]]; }

# IEC size ("100M", "2G", "512K" or plain bytes) to bytes.
to_bytes() { numfmt --from=iec "$1"; }

human() { numfmt --to=iec --suffix=B "$1"; }

# "<used %> <inode used %> <available bytes> <size bytes>" for a path, from the point of
# view of the kubelet: used is everything that is not available, so root-reserved blocks
# count as used.
fs_usage() {
  local size avail itotal iavail pct ipct=0
  read -r size avail itotal iavail < <(df -B1 --output=size,avail,itotal,iavail "$1" | tail -n 1)
  pct=$(((size - avail) * 100 / size))
  if [[ "$itotal" =~ ^[0-9]+$ ]] && ((itotal > 0)); then
    ipct=$(((itotal - iavail) * 100 / itotal))
  fi
  echo "$pct $ipct $avail $size"
}

# Every path a host process holds open, so the delete steps can leave those alone. With
# hostPID the container's /proc lists every process on the node; each fd link names the
# file as that process sees it. A containerised process's own paths can collide with a
# host path, which only ever makes this list longer, never shorter.
load_open_files() {
  local target fd_dirs=("$PROC"/[0-9]*/fd)
  [[ -d "${fd_dirs[0]}" ]] || return 0
  while IFS= read -r -d '' target; do
    OPEN_FILES["$target"]=1
  done < <(find "${fd_dirs[@]}" -mindepth 1 -maxdepth 1 -type l -printf '%l\0' 2>/dev/null)
}

host_path() { printf '%s' "${1#"$HOST"}"; }

is_open() { [[ -n "${OPEN_FILES[$(host_path "$1")]:-}" ]]; }

# Truncate or delete each file in a NUL-separated list of "<512-byte blocks><TAB><path>"
# records. Sets STEP_COUNT and STEP_BYTES. Open files are skipped for delete and kept
# for truncate, which is safe on an open file. min_bytes skips files that use less disk
# than that, which is how a sparse file with a large apparent size is left alone.
act_on() {
  local action=$1 min_bytes=${2:-0} rec blocks path bytes shown=0
  STEP_COUNT=0
  STEP_BYTES=0
  while IFS= read -r -d '' rec; do
    blocks=${rec%%$'\t'*}
    path=${rec#*$'\t'}
    bytes=$((blocks * 512))
    ((bytes > min_bytes)) || continue
    if [[ "$action" == delete ]] && is_open "$path"; then
      log "  kept $(host_path "$path"): a process has it open"
      continue
    fi
    if ! dry_run; then
      case "$action" in
        truncate) truncate -s 0 -- "$path" ;;
        delete) rm -f -- "$path" ;;
      esac || {
        error "could not $action $(host_path "$path")"
        continue
      }
    fi
    STEP_COUNT=$((STEP_COUNT + 1))
    STEP_BYTES=$((STEP_BYTES + bytes))
    if ((shown < DETAIL_LIMIT)); then
      if dry_run; then
        log "  would $action $(host_path "$path") ($(human "$bytes"))"
      else
        log "  ${action%e}ed $(host_path "$path") ($(human "$bytes"))"
      fi
      shown=$((shown + 1))
    fi
  done
  if ((STEP_COUNT > shown)); then
    log "  ... and $((STEP_COUNT - shown)) more"
  fi
}

# report_step <verb> [where]: "truncated 3 file(s), 1.2GB" or "would truncate ...".
report_step() {
  local verb=$1 where=${2:-}
  if dry_run; then
    log "  would $verb $STEP_COUNT file(s)${where:+ $where}, $(human "$STEP_BYTES")"
  else
    log "  ${verb%e}ed $STEP_COUNT file(s)${where:+ $where}, $(human "$STEP_BYTES")"
  fi
}

log_dirs() {
  local dir
  for dir in ${LOG_DIRS//,/ }; do
    [[ -d "$HOST$dir" ]] && printf '%s\n' "$HOST$dir"
  done
}

# find arguments that limit a log directory to its log files. Everything under /var/log
# is a log by convention, so the whole tree counts there. Any other directory (k3s keeps
# containerd.log next to the image store, for one) is read one level deep and only for
# names with ".log" in them, so a directory of data that happens to be listed cannot
# lose a file to a log rule.
log_scope() {
  case "${1#"$HOST"}" in
    /var/log | /var/log/*)
      SCOPE_DEPTH=()
      SCOPE_NAME=()
      ;;
    *)
      SCOPE_DEPTH=(-maxdepth 1)
      SCOPE_NAME=(-name '*.log*')
      ;;
  esac
}

# Journal files are binary, preallocated and owned by journald: a truncated one is a
# corrupt one. The journal step vacuums them properly instead.
step_logs() {
  local dir min
  log "== Truncating log files over $LOG_MAX_SIZE"
  min=$(to_bytes "$LOG_MAX_SIZE")
  while IFS= read -r dir; do
    log_scope "$dir"
    act_on truncate "$min" < <(find "$dir" -xdev "${SCOPE_DEPTH[@]}" \
      \( -type d -name journal -prune \) -o \
      \( -type f "${SCOPE_NAME[@]}" -size +"$((min / 1024))"k ! -name '*.journal' ! -name '*.journal~' \
      -printf '%b\t%p\0' \) 2>/dev/null)
    report_step truncate "in $(host_path "$dir")"
  done < <(log_dirs)
}

step_archived_logs() {
  local dir
  log "== Removing rotated and compressed logs"
  while IFS= read -r dir; do
    log_scope "$dir"
    act_on delete < <(find "$dir" -xdev "${SCOPE_DEPTH[@]}" \
      \( -type d -name journal -prune \) -o \
      \( -type f "${SCOPE_NAME[@]}" \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' -o -name '*.[0-9]' \) \
      -printf '%b\t%p\0' \) 2>/dev/null)
    report_step remove "in $(host_path "$dir")"
  done < <(log_dirs)
}

# The kubelet keeps a container's current and previous logs under /var/log/pods. A
# container that is still running holds its current log open, so the open-file check
# keeps it however old it is.
step_pod_logs() {
  local dir="$HOST/var/log/pods"
  log "== Removing pod logs untouched for more than $POD_LOG_MAX_AGE_DAYS days"
  if [[ ! -d "$dir" ]]; then
    log "  no /var/log/pods on this node"
    return
  fi
  act_on delete < <(find "$dir" -xdev -type f \( -name '*.log' -o -name '*.log.*' \) \
    -mtime +"$POD_LOG_MAX_AGE_DAYS" -printf '%b\t%p\0' 2>/dev/null)
  report_step remove
}

# Writable layers of running containers, read from the host's mount table: the
# upperdir of each overlay mount. Image layers are never in this list, so a file in an
# image is never touched, and exited containers' layers go with the container.
container_upperdirs() {
  local mountinfo="$PROC/1/mountinfo" opt
  [[ -r "$mountinfo" ]] || return 0
  awk '{ for (i = 1; i <= NF; i++) if ($i == "-") { if ($(i + 1) == "overlay") print $(i + 3); break } }' "$mountinfo" |
    tr ',' '\n' |
    while IFS= read -r opt; do
      [[ "$opt" == upperdir=* ]] && printf '%s\n' "${opt#upperdir=}"
    done | sort -u
}

# Crash dumps: core.<pid> files over HOOVER_CORE_DUMP_MIN_SIZE in /var/log and in
# running containers' writable layers, and everything in systemd-coredump's store.
# Anything written to in the last ten minutes may still be a dump in progress.
step_core_dumps() {
  local min dirs=() upper
  log "== Removing core dumps"
  min=$(to_bytes "$CORE_DUMP_MIN_SIZE")
  [[ -d "$HOST/var/log" ]] && dirs+=("$HOST/var/log")
  while IFS= read -r upper; do
    [[ -d "$HOST$upper" ]] && dirs+=("$HOST$upper")
  done < <(container_upperdirs)
  if ((${#dirs[@]} > 0)); then
    act_on delete "$min" < <(find "${dirs[@]}" -xdev -type f -regextype posix-extended \
      -regex '.*/core\.[0-9]+' -mmin +10 -printf '%b\t%p\0' 2>/dev/null)
    report_step remove
  fi
  if [[ -d "$HOST/var/lib/systemd/coredump" ]]; then
    act_on delete < <(find "$HOST/var/lib/systemd/coredump" -xdev -type f -mmin +10 \
      -printf '%b\t%p\0' 2>/dev/null)
    report_step remove "from systemd-coredump"
  fi
}

host_has() {
  local bin
  for bin in "$@"; do
    [[ -x "$HOST/usr/bin/$bin" || -x "$HOST/bin/$bin" || -x "$HOST/usr/sbin/$bin" ]] && return 0
  done
  return 1
}

step_journal() {
  log "== Vacuuming the systemd journal to $JOURNAL_MAX_SIZE"
  if ! host_has journalctl; then
    log "  no journalctl on this node"
    return
  fi
  if dry_run; then
    "${NSENTER[@]}" journalctl --disk-usage 2>&1 | sed 's/^/  /'
    log "  would run: journalctl --vacuum-size=$JOURNAL_MAX_SIZE"
    return
  fi
  if ! "${NSENTER[@]}" journalctl --vacuum-size="$JOURNAL_MAX_SIZE" 2>&1 | sed 's/^/  /'; then
    error "journalctl --vacuum-size failed"
  fi
}

# Cached downloads only. A package manager that is busy holds its lock and refuses,
# which is a warning, not a failure: the next run gets it.
step_package_cache() {
  local cmd=()
  log "== Cleaning the package manager's download cache"
  if host_has apt-get; then
    cmd=(apt-get clean)
  elif host_has dnf; then
    cmd=(dnf clean packages)
  elif host_has yum; then
    cmd=(yum clean packages)
  elif host_has zypper; then
    cmd=(zypper --non-interactive clean)
  else
    log "  no known package manager on this node"
    return
  fi
  if dry_run; then
    log "  would run: ${cmd[*]}"
    return
  fi
  if ! "${NSENTER[@]}" "${cmd[@]}" 2>&1 | sed 's/^/  /'; then
    warn "${cmd[*]} did not finish, probably because the package manager is busy"
  fi
}

detect_cri_socket() {
  local candidate
  if [[ -n "$CRI_SOCKET" ]]; then
    CRI_SOCKET="${CRI_SOCKET#unix://}"
    [[ -S "$HOST$CRI_SOCKET" ]] && return 0
    error "HOOVER_CRI_SOCKET=$CRI_SOCKET is not a socket on this node"
    return 1
  fi
  for candidate in "${CRI_SOCKET_CANDIDATES[@]}"; do
    if [[ -S "$HOST$candidate" ]]; then
      CRI_SOCKET="$candidate"
      return 0
    fi
  done
  warn "no container runtime socket found; skipping the container and image steps"
  return 1
}

crictl_() { "$CRICTL" --runtime-endpoint "unix://$HOST$CRI_SOCKET" --timeout 60s "$@"; }

# finishedAt to epoch seconds. crictl prints RFC 3339; some runtimes give nanoseconds.
# Anything else, including the zero time of a container that never ran, is 0: skipped.
finished_epoch() {
  local fin=$1 ts
  case "$fin" in
    0001-* | "") echo 0 ;;
    *T*)
      ts=$(date -d "$fin" +%s 2>/dev/null) || ts=0
      echo "$ts"
      ;;
    *[!0-9]*) echo 0 ;;
    *) echo $((fin / 1000000000)) ;;
  esac
}

# Sandbox ids and pod UIDs of the pods that are still running (sandbox Ready), one per
# line. Fails when the runtime cannot be asked, so the caller removes nothing.
ready_pods() {
  local json
  json=$(crictl_ pods --state ready -o json) || return 1
  jq -r '.items // [] | .[] | .id, (.metadata.uid // empty)' <<<"$json"
}

# A container that exited in a pod that is still running is an init container that has
# done its work, or the previous instance of one that restarted. The kubelet keeps the
# last dead instance of each on purpose: without an init container's record it runs the
# init containers again the next time the pod's main container exits. So only the
# containers of pods that are gone are removed, and a container whose pod cannot be
# told is kept.
step_exited_containers() {
  local now min_age id info fin ts age name sandbox uid ready removed=0 kept=0 running=0 ids
  declare -A READY=()
  log "== Removing containers of finished pods that exited more than ${CONTAINER_MIN_AGE_HOURS}h ago"
  min_age=$((CONTAINER_MIN_AGE_HOURS * 3600))
  now=$(date +%s)
  if ! ids=$(crictl_ ps -a --state exited -q 2>&1); then
    error "crictl ps failed: $ids"
    return
  fi
  if ! ready=$(ready_pods); then
    error "could not list the running pods, so no container is removed"
    return
  fi
  for id in $ready; do
    READY["$id"]=1
  done
  for id in $ids; do
    info=$(crictl_ inspect -o json "$id" 2>/dev/null) || continue
    fin=$(jq -r '.status.finishedAt // ""' <<<"$info")
    ts=$(finished_epoch "$fin")
    age=$((now - ts))
    name=$(jq -r '[.status.labels["io.kubernetes.pod.namespace"] // "-", .status.labels["io.kubernetes.pod.name"] // "-", .status.metadata.name // "-"] | join("/")' <<<"$info" 2>/dev/null)
    if ((ts <= 0 || age <= min_age)); then
      kept=$((kept + 1))
      continue
    fi
    sandbox=$(jq -r '.info.sandboxID // ""' <<<"$info" 2>/dev/null)
    uid=$(jq -r '.status.labels["io.kubernetes.pod.uid"] // ""' <<<"$info" 2>/dev/null)
    if [[ -z "$sandbox" && -z "$uid" ]]; then
      kept=$((kept + 1))
      continue
    fi
    if [[ -n "$sandbox" && -n "${READY[$sandbox]:-}" ]] || [[ -n "$uid" && -n "${READY[$uid]:-}" ]]; then
      running=$((running + 1))
      continue
    fi
    if dry_run; then
      log "  would remove ${id:0:13} $name (exited $((age / 3600))h ago)"
    elif crictl_ rm "$id" >/dev/null 2>&1; then
      log "  removed ${id:0:13} $name (exited $((age / 3600))h ago)"
    else
      warn "the runtime refused to remove ${id:0:13} $name"
      continue
    fi
    removed=$((removed + 1))
  done
  if dry_run; then
    log "  would remove $removed container(s), keep $kept, and $running of running pods"
  else
    log "  removed $removed container(s), kept $kept, and $running of running pods"
  fi
}

# Image references as the runtime records them: docker.io/library/ for a bare name,
# docker.io/ for a name with no registry host.
JQ_NORMALISE='def norm:
  if test("^sha256:") then .
  elif test("^[^/]+[.:][^/]*/") or startswith("localhost/") then .  # DevSkim: ignore DS162092
  elif contains("/") then "docker.io/" + .
  else "docker.io/library/" + . end;'

# Images that nothing on the node uses. Kept: pinned images, images any container uses
# (running or exited, so the exited-containers step decides what is released), and every
# pod sandbox's image. The last is why this does not use `crictl rmi --prune`: that
# counts containers only, and a runtime that does not pin its pause image would lose it.
#
# Fails closed: if the runtime cannot list its sandboxes, cannot inspect one that still
# exists, or a running sandbox does not name its image, this returns 1 and the images
# step removes nothing. A sandbox that is gone by the time it is inspected is skipped
# (the kubelet removes dead sandboxes all the time), and so is a stopped one that names
# no image, since a running sandbox protects the image new sandboxes need. This pod runs
# in a sandbox itself, so finding none at all is also a failure. Reasons go to stderr:
# stdout is the list.
unused_images() {
  local images containers pods pod info ref state still sandbox_refs='[]'
  images=$(crictl_ images -o json) || return 1
  containers=$(crictl_ ps -a -o json) || return 1
  pods=$(crictl_ pods -q) || {
    log "could not list the pod sandboxes" >&2
    return 1
  }
  for pod in $pods; do
    if ! info=$(crictl_ inspectp -o json "$pod" 2>/dev/null); then
      still=$(crictl_ pods -q --id "$pod") || return 1
      [[ -z "$still" ]] && continue
      log "could not inspect pod sandbox ${pod:0:13}" >&2
      return 1
    fi
    ref=$(jq -r '.info.image // ""' <<<"$info") || return 1
    if [[ -z "$ref" ]]; then
      state=$(jq -r '.status.state // ""' <<<"$info")
      [[ "$state" == SANDBOX_NOTREADY ]] && continue
      log "pod sandbox ${pod:0:13} (${state:-no state}) does not name its image" >&2
      return 1
    fi
    sandbox_refs=$(jq -c --arg r "$ref" '. + [$r]' <<<"$sandbox_refs")
  done
  if [[ "$sandbox_refs" == '[]' ]]; then
    log "no pod sandbox named its image, so the pause image cannot be told apart" >&2
    return 1
  fi
  # The three documents go in on stdin, not as --argjson: a busy node's `crictl ps -a` is
  # well over the kernel's 128 KiB limit for one argument, and jq then never starts
  # ("Argument list too long"). printf is a bash builtin, so it has no such limit.
  printf '%s\n%s\n%s\n' "$images" "$containers" "$sandbox_refs" | jq -rn "$JQ_NORMALISE"'
    input as $images | input as $containers | input as $sandboxes
    | ([$containers.containers[] | .imageRef, .image.image] | map(select(. != null and . != ""))) as $used
    | ($sandboxes | map(norm)) as $sandbox
    | $images.images[]
    | select((.pinned // false) | not)
    | select(.id as $id | $used | index($id) | not)
    | select(([.id] + (.repoTags // []) + (.repoDigests // [])) as $refs
             | any($sandbox[]; . as $s | $refs | index($s)) | not)
    | [.id, (.size | tostring), ((.repoTags // [])[0] // (.repoDigests // [])[0] // .id)] | @tsv
  '
}

# Largest first, so the fewest images are pulled again later. With
# HOOVER_IMAGES_TARGET_PERCENT set, it stops once the node is that full or less, which
# keeps the rest cached; at 0 every unused image goes. A dry run cannot measure as it
# goes, so it projects from the image sizes, which overstates what shared layers free.
step_images() {
  local list id size ref count=0 bytes=0 kept=0 pct avail fs_size used
  if ((IMAGES_TARGET > 0)); then
    log "== Removing images nothing on the node uses, largest first, until / is ${IMAGES_TARGET}% used"
  else
    log "== Removing images nothing on the node uses"
  fi
  if ! list=$(unused_images | sort -t $'\t' -k2,2nr); then
    error "could not tell which images the runtime's containers and pod sandboxes use, so no image is removed"
    return
  fi
  read -r pct _ avail fs_size < <(fs_usage "$HOST$THRESHOLD_PATH")
  used=$((fs_size - avail))
  while IFS=$'\t' read -r id size ref; do
    [[ -n "$id" ]] || continue
    if ((IMAGES_TARGET > 0)); then
      if dry_run; then
        pct=$(((used - bytes) * 100 / fs_size))
      else
        read -r pct _ _ _ < <(fs_usage "$HOST$THRESHOLD_PATH")
      fi
      if ((pct <= IMAGES_TARGET)); then
        kept=$((kept + 1))
        continue
      fi
    fi
    if dry_run; then
      log "  would remove $ref ($(human "$size"))"
    elif crictl_ rmi "$id" >/dev/null 2>&1; then
      log "  removed $ref ($(human "$size"))"
    else
      # Most likely a container started with it since the list was made.
      warn "the runtime refused to remove $ref"
      continue
    fi
    count=$((count + 1))
    bytes=$((bytes + size))
  done <<<"$list"
  if dry_run; then
    log "  would remove $count image(s), up to $(human "$bytes") before shared layers; would keep $kept unused"
  else
    log "  removed $count image(s), up to $(human "$bytes") before shared layers; kept $kept unused"
  fi
}

preflight() {
  local proc_root host_root
  if [[ ! -d "$HOST/var" ]]; then
    error "the host's root filesystem is not mounted at $HOST"
    return 1
  fi
  is_true "$PREFLIGHT" || return 0
  # PID 1's root is the host's / only when this pod shares the host PID namespace AND
  # $HOST is the host's real root. Both are needed: the open-file check reads every
  # host process's fds, and nsenter enters PID 1's mount namespace.
  proc_root=$(stat -L -c '%d:%i' "$PROC/1/root/" 2>/dev/null) || proc_root=none
  host_root=$(stat -L -c '%d:%i' "$HOST/" 2>/dev/null) || host_root=missing
  if [[ "$proc_root" != "$host_root" ]]; then
    error "PID 1 is not the host's init, or $HOST is not the host's root: run with hostPID and a hostPath mount of /"
    return 1
  fi
}

result() {
  local mode=$1 before=$2 after=$3 freed=$4
  echo "HOOVER_RESULT node=$NODE mode=$mode used_before=${before}% used_after=${after}% freed_bytes=$freed warnings=$WARNINGS errors=$ERRORS"
}

main() {
  local pct ipct avail_before pct_after avail_after mode step freed
  log "harddisk-hoover on $NODE (dry run: $DRY_RUN, threshold: ${THRESHOLD}%)"
  if ! preflight; then
    result error 0 0 0
    exit 2
  fi
  read -r pct ipct avail_before _ < <(fs_usage "$HOST$THRESHOLD_PATH")
  log "$THRESHOLD_PATH is ${pct}% used (inodes ${ipct}%), $(human "$avail_before") available"

  if ((THRESHOLD > 0 && pct < THRESHOLD && ipct < THRESHOLD)); then
    log "below the ${THRESHOLD}% threshold, nothing to do"
    result skipped "$pct" "$pct" 0
    exit 0
  fi

  load_open_files
  log "${#OPEN_FILES[@]} open files on the host"

  for step in logs archived-logs pod-logs core-dumps journal package-cache; do
    if step_enabled "$step"; then
      "step_${step//-/_}"
    fi
  done
  if step_enabled exited-containers || step_enabled images; then
    if detect_cri_socket; then
      log "container runtime at $CRI_SOCKET"
      step_enabled exited-containers && step_exited_containers
      step_enabled images && step_images
    fi
  fi

  read -r pct_after _ avail_after _ < <(fs_usage "$HOST$THRESHOLD_PATH")
  freed=$((avail_after - avail_before))
  ((freed < 0)) && freed=0
  mode=cleaned
  dry_run && mode=dry-run
  log "$THRESHOLD_PATH is ${pct_after}% used, $(human "$avail_after") available ($(human "$freed") freed)"
  result "$mode" "$pct" "$pct_after" "$freed"
  ((ERRORS == 0))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
