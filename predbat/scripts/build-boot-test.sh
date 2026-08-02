#!/usr/bin/env bash
# Build (optionally) and boot-test a predbat addon Docker image variant.
#
# Verifies:
#   - the container boots and reaches the "update apps.yaml" prompt (proof the
#     entrypoint made it through startup without crashing)
#   - no "warning" lines appear in the boot logs (e.g. s6-overlay deprecations -
#     these don't stop the apps.yaml prompt from appearing, so nothing else here
#     would otherwise catch them)
#   - for alpine/slim (s6-based; noble has no s6-overlay), the predbat service is
#     up and wait-for-ha is in an expected state
#
# Used both by CI (.github/workflows/lint-build-boot-test.yml passes an already-built
# --tag from its docker/build-push-action step) and for local/manual verification
# (omit --tag and this script builds the image itself, always sourcing versions.env -
# see CLAUDE.md's "Testing a Dockerfile change locally" section for why hand-typing
# --build-arg flags is exactly what caused a false-pass here previously).
#
# Usage:
#   predbat/scripts/build-boot-test.sh <alpine|noble|slim> [--platform linux/amd64] [--timeout 90] [--tag <existing-image-tag>]

set -euo pipefail

variant=""
platform=""
timeout=90
tag=""

while [ $# -gt 0 ]; do
  case "$1" in
    alpine|noble|slim) variant="$1"; shift ;;
    --platform) platform="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --tag) tag="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$variant" ]; then
  echo "usage: $0 <alpine|noble|slim> [--platform linux/amd64] [--timeout 90] [--tag <existing-image-tag>]" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

platform_args=()
[ -n "$platform" ] && platform_args=(--platform "$platform")

if [ -z "$tag" ]; then
  # shellcheck disable=SC1091
  source "$repo_root/versions.env"
  tag="predbat-boot-test:${variant}"
  echo "==> Building predbat/Dockerfile.${variant} (PREDBAT_VERSION=$PREDBAT_VERSION ADDON_VERSION=$ADDON_VERSION S6_VERSION=$S6_VERSION)"
  docker build "${platform_args[@]}" \
    -f "$repo_root/predbat/Dockerfile.${variant}" \
    --build-arg "PREDBAT_VERSION=$PREDBAT_VERSION" \
    --build-arg "ADDON_VERSION=$ADDON_VERSION" \
    --build-arg "S6_VERSION=$S6_VERSION" \
    -t "$tag" "$repo_root/predbat"
fi

container="predbat-boot-test-${variant}-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Starting $tag"
docker run -d --name "$container" "${platform_args[@]}" "$tag" >/dev/null

echo "==> Waiting up to ${timeout}s for the apps.yaml prompt..."
elapsed=0
found=0
logs=""
while [ "$elapsed" -lt "$timeout" ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
    echo "FAIL: container exited early" >&2
    docker logs "$container" >&2
    exit 1
  fi
  logs="$(docker logs "$container" 2>&1)"
  if grep -qi "update apps.yaml" <<<"$logs"; then
    found=1
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

if [ "$found" -ne 1 ]; then
  echo "FAIL: apps.yaml prompt not seen within ${timeout}s" >&2
  echo "$logs" >&2
  exit 1
fi
echo "==> Boot prompt reached"

if grep -qi "warning" <<<"$logs"; then
  echo "FAIL: warning(s) found in boot logs:" >&2
  grep -i "warning" <<<"$logs" >&2
  exit 1
fi
echo "==> No warnings in boot logs"

if [ "$variant" = "alpine" ] || [ "$variant" = "slim" ]; then
  predbat_status="$(docker exec "$container" /package/admin/s6/command/s6-svstat /run/service/predbat)"
  echo "==> predbat: $predbat_status"
  if ! grep -q "^up" <<<"$predbat_status"; then
    echo "FAIL: predbat service is not up: $predbat_status" >&2
    exit 1
  fi

  waitforha_status="$(docker exec "$container" /package/admin/s6/command/s6-svstat /run/service/wait-for-ha)"
  echo "==> wait-for-ha: $waitforha_status"
  # wait-for-ha is optional (only polls HA if WAIT_FOR_HA_HOST/_PORT are set): "up" (actively
  # waiting/polling) or a self-triggered "down (signal SIGTERM)" (its documented no-op-when-
  # unconfigured behavior) are both fine; anything else suggests a crash loop.
  if ! grep -qE "^(up|down \(signal SIGTERM\))" <<<"$waitforha_status"; then
    echo "FAIL: wait-for-ha service in unexpected state: $waitforha_status" >&2
    exit 1
  fi
fi

echo "==> PASS: ${variant} boots cleanly, no warnings, services in expected state"
