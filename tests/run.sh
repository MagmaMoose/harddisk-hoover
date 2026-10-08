#!/usr/bin/env bash
# Run the unit tests inside the image, so they exercise the same find, coreutils and
# bash the cleanup ships with. Usage: tests/run.sh [image]  (default: builds one)
set -euo pipefail
cd "$(dirname "$0")/.."
image="${1:-}"
if [[ -z "$image" ]]; then
  image=harddisk-hoover:test
  docker build -q -t "$image" . >/dev/null
fi
docker run --rm --user 0 --entrypoint sh -v "$PWD:/src:ro" -w /src "$image" \
  -c 'apk add --no-cache bats python3 >/dev/null && bats tests/hoover.bats tests/controller.bats'
