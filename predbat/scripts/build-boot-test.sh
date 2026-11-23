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
# The same boot checks then run again as the predbat user (9005) with
# --cap-drop ALL and no-new-privileges.
# Then a second phase verifies, without waiting for
# Predbat itself (it cannot start without Home Assistant):
#   - pip has been removed (`python3 -m pip --version` fails)
#   - the image defines a HEALTHCHECK requesting 127.0.0.1:5052/dash
#   - after dropping `template: true` from the container's apps.yaml, the
#     web-login WARNING appears and is the only "warning" in the logs
#
# Used both by CI (.github/workflows/lint-build-boot-test.yml passes an already-built
# --tag from its docker/build-push-action step) and for local/manual verification
# (omit --tag and this script builds the image itself, always sourcing versions.env -
# see CLAUDE.md's "Testing a Dockerfile change locally" section for why hand-typing
# --build-arg flags is exactly what caused a false-pass here previously).
#
# Usage:
#   predbat/scripts/build-boot-test.sh <alpine|noble|slim> [--platform linux/amd64] [--timeout 90] [--start-timeout 120] [--tag <existing-image-tag>]

set -euo pipefail

variant=""
platform=""
timeout=90
start_timeout=120
tag=""

while [ $# -gt 0 ]; do
  case "$1" in
    alpine|noble|slim) variant="$1"; shift ;;
    --platform) platform="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --start-timeout) start_timeout="$2"; shift 2 ;;
    --tag) tag="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$variant" ]; then
  echo "usage: $0 <alpine|noble|slim> [--platform linux/amd64] [--timeout 90] [--start-timeout 120] [--tag <existing-image-tag>]" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

platform_args=()
[ -n "$platform" ] && platform_args=(--platform "$platform")

if [ -z "$tag" ]; then
  # shellcheck disable=SC1091
  source "$repo_root/versions.env"
  tag="predbat-boot-test:${variant}"
  # Same tag-to-commit resolution as CI: the Dockerfiles fetch Predbat by commit
  batpred=https://github.com/springfall2008/batpred.git
  PREDBAT_SHA="$(git ls-remote "$batpred" "refs/tags/${PREDBAT_VERSION}^{}" | cut -f1)"
  [ -n "$PREDBAT_SHA" ] || PREDBAT_SHA="$(git ls-remote "$batpred" "refs/tags/${PREDBAT_VERSION}" | cut -f1)"
  if ! [[ "$PREDBAT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "could not resolve Predbat tag ${PREDBAT_VERSION} to a commit" >&2
    exit 1
  fi
  echo "==> Building predbat/Dockerfile.${variant} (PREDBAT_VERSION=$PREDBAT_VERSION PREDBAT_SHA=$PREDBAT_SHA ADDON_VERSION=$ADDON_VERSION S6_VERSION=$S6_VERSION)"
  docker build "${platform_args[@]}" \
    -f "$repo_root/predbat/Dockerfile.${variant}" \
    --build-arg "PREDBAT_VERSION=$PREDBAT_VERSION" \
    --build-arg "PREDBAT_SHA=$PREDBAT_SHA" \
    --build-arg "ADDON_VERSION=$ADDON_VERSION" \
    --build-arg "S6_VERSION=$S6_VERSION" \
    --build-arg "S6_SHA256_NOARCH=$S6_SHA256_NOARCH" \
    --build-arg "S6_SHA256_AMD64=$S6_SHA256_AMD64" \
    --build-arg "S6_SHA256_ARM64=$S6_SHA256_ARM64" \
    --build-arg "S6_SHA256_ARM=$S6_SHA256_ARM" \
    -t "$tag" "$repo_root/predbat"
fi

container="predbat-boot-test-${variant}-$$"
nonroot_container="predbat-boot-test-${variant}-nonroot-$$"

cleanup() {
  docker rm -f "$container" "$nonroot_container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Start the image as $1 (extra docker run options follow), wait for the
# apps.yaml prompt, check the logs hold no warning and (alpine/slim) the s6
# services are in their expected states. Sets $logs.
boot_and_check() {
  local container="$1"
  shift
  echo "==> Starting $tag${*:+ ($*)}"
  docker run -d --name "$container" "${platform_args[@]}" "$@" "$tag" >/dev/null

  echo "==> Waiting up to ${timeout}s for the apps.yaml prompt..."
  local elapsed=0 found=0
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
}

boot_and_check "$container"
echo "==> Phase 1 passed: ${variant} boots cleanly, no warnings, services in expected state"

# ---------------------------------------------------------------------------
# Non-root phase: the same checks with the image's
# predbat user, no capabilities and no-new-privileges, as the README's
# "Running securely" example runs it.
# ---------------------------------------------------------------------------
boot_and_check "$nonroot_container" --user 9005:9005 --cap-drop ALL --security-opt no-new-privileges:true
pid1_uid="$(docker exec "$nonroot_container" awk '/^Uid:/ {print $2}' /proc/1/status)"
if [ "$pid1_uid" != "9005" ]; then
  echo "FAIL: non-root run: PID 1 runs as uid ${pid1_uid}, expected 9005" >&2
  exit 1
fi
docker rm -f "$nonroot_container" >/dev/null 2>&1 || true
echo "==> Non-root phase passed: ${variant} boots as 9005 with --cap-drop ALL and no-new-privileges"

# ---------------------------------------------------------------------------
# Phase 2. Test-only: the image is not changed, only
# this container's /config/apps.yaml. Predbat itself cannot start in CI (no
# Home Assistant), so nothing here waits for it.
# ---------------------------------------------------------------------------
# The only "warning" allowed in the logs: run.docker.sh / run.standalone.sh's
# notice that the web interface has no login
login_warning="WARNING: the Predbat web interface (port 5052) has no login."

# pip has been removed from the image
if docker exec "$container" python3 -m pip --version >/dev/null 2>&1; then
  echo "FAIL: pip is still installed in the image (python3 -m pip --version succeeded)" >&2
  exit 1
fi
echo "==> pip is not installed"

# The image defines a HEALTHCHECK that requests Predbat's dashboard page
healthcheck="$(docker inspect --format '{{json .Config.Healthcheck}}' "$tag")"
echo "==> Healthcheck: $healthcheck"
if [ -z "$healthcheck" ] || [ "$healthcheck" = "null" ] || ! grep -qF "127.0.0.1:5052/dash" <<<"$healthcheck"; then
  echo "FAIL: image has no HEALTHCHECK requesting 127.0.0.1:5052/dash" >&2
  exit 1
fi

# With template: true removed, the web-login warning appears
echo "==> Phase 2: removing 'template: true' from /config/apps.yaml"
docker exec "$container" sed -i '/^[^#]*template: true/d' /config/apps.yaml
if docker exec "$container" grep -q "^[^#]*template: true" /config/apps.yaml; then
  echo "FAIL: could not remove 'template: true' from /config/apps.yaml" >&2
  exit 1
fi

echo "==> Waiting up to ${start_timeout}s for the web-login warning..."
elapsed=0
seen_warning=0
while [ "$elapsed" -lt "$start_timeout" ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
    echo "FAIL: container exited during phase 2" >&2
    docker logs "$container" >&2
    exit 1
  fi
  logs="$(docker logs "$container" 2>&1)"
  if grep -qF "$login_warning" <<<"$logs"; then
    seen_warning=1
    echo "==> Web-login warning seen after ${elapsed}s"
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

if [ "$seen_warning" -ne 1 ]; then
  echo "FAIL: web-login warning not seen within ${start_timeout}s" >&2
  echo "$logs" >&2
  exit 1
fi

other_warnings="$(grep -i "warning" <<<"$logs" | grep -vF "$login_warning" || true)"
if [ -n "$other_warnings" ]; then
  echo "FAIL: warning(s) other than the web-login notice found in the logs:" >&2
  echo "$other_warnings" >&2
  exit 1
fi
echo "==> No warnings in the logs apart from the web-login notice"

# Done with this container: don't sit through Predbat's no-HA restart loop
docker rm -f "$container" >/dev/null 2>&1 || true

echo "==> PASS: ${variant} boots cleanly as root and as 9005, pip removed, HEALTHCHECK set, web-login warning shown"
