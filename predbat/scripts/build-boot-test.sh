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
# Then a second phase (homelab-runbooks #470) edits the container's apps.yaml to
# drop `template: true`, so Predbat itself starts, and verifies:
#   - the web-login WARNING appears (no web_username/web_password set) and it is
#     the only "warning" anywhere in the logs
#   - Docker reports the container healthy, or the web port answers inside it
#   - pip has been removed (`python3 -m pip --version` fails)
#
# Used both by CI (.github/workflows/lint-build-boot-test.yml passes an already-built
# --tag from its docker/build-push-action step) and for local/manual verification
# (omit --tag and this script builds the image itself, always sourcing versions.env -
# see CLAUDE.md's "Testing a Dockerfile change locally" section for why hand-typing
# --build-arg flags is exactly what caused a false-pass here previously).
#
# Usage:
#   predbat/scripts/build-boot-test.sh <alpine|noble|slim> [--platform linux/amd64] [--timeout 90] [--start-timeout 300] [--tag <existing-image-tag>]

set -euo pipefail

variant=""
platform=""
timeout=90
start_timeout=300
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
  echo "usage: $0 <alpine|noble|slim> [--platform linux/amd64] [--timeout 90] [--start-timeout 300] [--tag <existing-image-tag>]" >&2
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

echo "==> Phase 1 passed: ${variant} boots cleanly, no warnings, services in expected state"

# ---------------------------------------------------------------------------
# Phase 2: let Predbat start (homelab-runbooks #470). Test-only: the image is
# not changed, only this container's /config/apps.yaml.
# ---------------------------------------------------------------------------
# The only "warning" allowed in the logs: run.docker.sh / run.standalone.sh's
# notice that the web interface has no login (D13)
login_warning="WARNING: the Predbat web interface (port 5052) has no login."

echo "==> Phase 2: removing 'template: true' from /config/apps.yaml"
docker exec "$container" sed -i '/^[^#]*template: true/d' /config/apps.yaml
if docker exec "$container" grep -q "^[^#]*template: true" /config/apps.yaml; then
  echo "FAIL: could not remove 'template: true' from /config/apps.yaml" >&2
  exit 1
fi

# The same request the image's HEALTHCHECK makes, run inside the container
web_probe=(python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5052/', timeout=4)")

echo "==> Waiting up to ${start_timeout}s for the web-login warning and for Predbat's web interface..."
elapsed=0
seen_warning=0
web_up=0
while [ "$elapsed" -lt "$start_timeout" ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
    echo "FAIL: container exited during phase 2" >&2
    docker logs "$container" >&2
    exit 1
  fi
  logs="$(docker logs "$container" 2>&1)"
  if [ "$seen_warning" -eq 0 ] && grep -qF "$login_warning" <<<"$logs"; then
    seen_warning=1
    echo "==> Web-login warning seen after ${elapsed}s"
  fi
  if [ "$seen_warning" -eq 1 ]; then
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container")"
    if [ "$health" = "healthy" ]; then
      echo "==> Container reported healthy after ${elapsed}s"
      web_up=1
      break
    fi
    if docker exec "$container" "${web_probe[@]}" >/dev/null 2>&1; then
      echo "==> Web interface answered on 127.0.0.1:5052 after ${elapsed}s (health: ${health:-none})"
      web_up=1
      break
    fi
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

if [ "$seen_warning" -ne 1 ]; then
  echo "FAIL: web-login warning not seen within ${start_timeout}s" >&2
  echo "$logs" >&2
  exit 1
fi
if [ "$web_up" -ne 1 ]; then
  echo "FAIL: Predbat's web interface did not answer within ${start_timeout}s" >&2
  echo "$logs" >&2
  exit 1
fi

logs="$(docker logs "$container" 2>&1)"
other_warnings="$(grep -i "warning" <<<"$logs" | grep -vF "$login_warning" || true)"
if [ -n "$other_warnings" ]; then
  echo "FAIL: warning(s) other than the web-login notice found in the logs:" >&2
  echo "$other_warnings" >&2
  exit 1
fi
echo "==> No warnings in the logs apart from the web-login notice"

if docker exec "$container" python3 -m pip --version >/dev/null 2>&1; then
  echo "FAIL: pip is still installed in the image (python3 -m pip --version succeeded)" >&2
  exit 1
fi
echo "==> pip is not installed"

echo "==> PASS: ${variant} boots cleanly, Predbat starts, warnings and pip as expected"
