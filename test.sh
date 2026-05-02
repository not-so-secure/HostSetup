#!/usr/bin/env bash
# Test AllInOne.sh inside a clean Ubuntu 22.04 container.
#
# Usage:
#   ./test.sh                          # quick test: apt + go + gotools
#   ./test.sh --only=apt,go,gotools    # same, explicit
#   ./test.sh --only=redtools          # test one section
#   ./test.sh --force                  # force reinstall
#   ./test.sh full                     # interactive full run (prompts for heavy tools)
#   ./test.sh shell                    # drop into container shell

set -euo pipefail

IMAGE=autosetup-test
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Rebuild image if script changed since last build
docker build -q -t "$IMAGE" "$SCRIPT_DIR"

MODE="${1:-quick}"

# Common docker run flags
BASE_ARGS=(
    --rm
    --cap-add=NET_ADMIN
    # Live-mount script so edits don't need a rebuild
    -v "$SCRIPT_DIR/AllInOne.sh:/root/AllInOne.sh:ro"
)

case "$MODE" in
    shell)
        docker run -it "${BASE_ARGS[@]}" "$IMAGE" bash
        ;;
    full)
        docker run -it "${BASE_ARGS[@]}" "$IMAGE" bash /root/AllInOne.sh
        ;;
    *)
        # Pass any args directly to the script; default to quick section set
        SCRIPT_ARGS=("$@")
        if [[ ${#SCRIPT_ARGS[@]} -eq 0 ]]; then
            SCRIPT_ARGS=(--only=apt,go,gotools)
        fi
        docker run -it "${BASE_ARGS[@]}" "$IMAGE" \
            bash /root/AllInOne.sh "${SCRIPT_ARGS[@]}"
        ;;
esac
