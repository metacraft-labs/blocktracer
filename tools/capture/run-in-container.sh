#!/usr/bin/env bash
# Run the capture harness inside the PINNED capture container (VD.0).
#
#   tools/capture/run-in-container.sh canary            # the tier-1 determinism check
#   tools/capture/run-in-container.sh capture           # full regeneration
#   tools/capture/run-in-container.sh capture --view home --size wide
#   tools/capture/run-in-container.sh coverage
#   tools/capture/run-in-container.sh shell             # a shell in the image
#
# The image fixes the browser build, the fonts and the renderer flags, so an
# exact-hash comparison measures the product rather than the runner. The site
# itself is built on the HOST, before the container starts: the exporter is a
# Nim toolchain the image deliberately does not carry, and `dist/` is already
# byte-reproducible from a fixed seed, so building it inside would add a second
# variable without removing one.
#
# `set -euo pipefail` is deliberate. This script is the thing that decides
# whether a tier-1 verdict is trustworthy, so it must abort rather than proceed
# on a partial setup.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

IMAGE_NAME="${VD0_IMAGE_NAME:-blocktracer-vd0-capture}"
IMAGE_TAG="${VD0_IMAGE_TAG:-pw1.62.1}"
IMAGE="$IMAGE_NAME:$IMAGE_TAG"
BASE_IMAGE="mcr.microsoft.com/playwright@sha256:dcc5531e97840b9b5e794f2814476b21571c5124a3fca2267d73041f56e7580e"

die() { echo "run-in-container: $*" >&2; exit 2; }

# VD0_DRY_RUN=1 prints the docker invocations instead of running them, so the
# pinned-container path is reviewable on a machine with no working daemon.
DRY="${VD0_DRY_RUN:-0}"

command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
if [[ "$DRY" != "1" ]]; then
  docker info >/dev/null 2>&1 || die "the docker daemon is not reachable (start Docker Desktop / dockerd)"
fi

mode="${1:-capture}"; shift || true

# ── 1. Build the site on the host ──────────────────────────────────────────
if [[ "${VD0_SKIP_BUILD:-0}" != "1" ]]; then
  if command -v nim >/dev/null 2>&1; then
    echo "==> building client/dist on the host"
    ( cd "$REPO_ROOT/client" && nim c -r --mm:orc -d:isServer -d:release --hints:off src/static_export.nim >/dev/null )
  elif [[ -d "$REPO_ROOT/client/dist" ]]; then
    echo "!   nim not on PATH — capturing the existing client/dist"
  else
    die "nim is not on PATH and there is no client/dist to capture"
  fi
fi
[[ -d "$REPO_ROOT/client/dist" ]] || die "no client/dist to capture"

# ── 2. Build the pinned image ──────────────────────────────────────────────
PKG_PW="$(node -e 'process.stdout.write(require("'"$HERE"'/package.json").dependencies.playwright)')"

# Architecture is part of the pin, so it is settable and recorded rather than
# left to whatever the host happens to be. Unset means "the host's native
# architecture", which is right for local iteration; CI that wants baselines
# comparable with another runner's must set it explicitly, e.g.
#   VD0_PLATFORM=linux/amd64 tools/capture/run-in-container.sh canary
platform_args=()
[[ -n "${VD0_PLATFORM:-}" ]] && platform_args=(--platform "$VD0_PLATFORM")

if [[ "$DRY" == "1" ]]; then
  echo "==> [dry run] docker build --pull ${platform_args[*]} -t $IMAGE $HERE"
  IMAGE_DIGEST="(dry-run)"; IMAGE_ARCH="$(uname -m)"; IMAGE_OS="linux"; IMAGE_PW="$PKG_PW"
else
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1 || [[ "${VD0_REBUILD_IMAGE:-0}" == "1" ]]; then
    echo "==> building the pinned capture image $IMAGE"
    docker build --pull "${platform_args[@]}" -t "$IMAGE" "$HERE"
  fi

  # ── 3. Record exactly which image this is ────────────────────────────────
  # The per-ARCHITECTURE identity, not the multi-arch index digest: amd64 and
  # arm64 Chromium do not rasterise text identically, so a hash is only
  # comparable with another hash produced on the same architecture. Recording
  # it means a cross-architecture comparison shows up as one.
  IMAGE_DIGEST="$(docker image inspect --format '{{index .Id}}' "$IMAGE")"
  IMAGE_ARCH="$(docker image inspect --format '{{.Architecture}}' "$IMAGE")"
  IMAGE_OS="$(docker image inspect --format '{{.Os}}' "$IMAGE")"

  # ── 4. Assert the npm package and the image's browsers agree ─────────────
  IMAGE_PW="$(docker run --rm --entrypoint cat "$IMAGE" /vd0-playwright-version | tr -d '[:space:]')"
  if [[ "$IMAGE_PW" != "$PKG_PW" ]]; then
    die "playwright version skew: image has $IMAGE_PW, tools/capture/package.json pins $PKG_PW.
     A tier-1 hash produced under a skewed pair means nothing. Rebuild the image
     (VD0_REBUILD_IMAGE=1) after updating the base digest in the Dockerfile."
  fi

  # A host-installed node_modules shadows the image's copy (Node resolves ESM
  # by walking up from the importing file). Same version is fine; anything else
  # is the skew this check exists to prevent.
  if [[ -f "$HERE/node_modules/playwright/package.json" ]]; then
    HOST_PW="$(node -e 'process.stdout.write(require("'"$HERE"'/node_modules/playwright/package.json").version)')"
    [[ "$HOST_PW" == "$IMAGE_PW" ]] || die "tools/capture/node_modules has playwright $HOST_PW but the image has $IMAGE_PW; \
remove node_modules or reinstall the pinned version"
  fi
fi

echo "==> pinned container"
echo "    image      $IMAGE"
echo "    base       $BASE_IMAGE"
echo "    id         $IMAGE_DIGEST"
echo "    platform   $IMAGE_OS/$IMAGE_ARCH"
echo "    playwright $IMAGE_PW"

# ── 5. Run ─────────────────────────────────────────────────────────────────
case "$mode" in
  capture)  cmd=(tools/capture/capture.mjs --no-build "$@") ;;
  canary)   cmd=(tools/capture/check-canary.mjs --no-build "$@") ;;
  coverage) cmd=(tools/capture/check-coverage.mjs "$@") ;;
  gate)     cmd=(tools/capture/require-deterministic.mjs "$@") ;;
  selftest) cmd=(tools/capture/selftest.mjs "$@") ;;
  shell)    cmd=() ;;
  *) die "unknown mode '$mode' (capture | canary | coverage | gate | selftest | shell)" ;;
esac

docker_args=(
  --rm
  --init
  "${platform_args[@]}"
  # Chromium's renderer uses a lot of shared memory; the default 64 MB /dev/shm
  # makes it crash in ways that look exactly like nondeterminism.
  --ipc=host
  --shm-size=1g
  # No network: the capture serves dist/ from loopback inside the container, so
  # anything that reached out would be an unpinned input by definition.
  --network=none
  --user "$(id -u):$(id -g)"
  --env "VD0_IN_CONTAINER=1"
  --env "VD0_CONTAINER_IMAGE=$IMAGE"
  --env "VD0_CONTAINER_DIGEST=$IMAGE_DIGEST"
  --env "VD0_CONTAINER_PLATFORM=$IMAGE_OS/$IMAGE_ARCH"
  --env "HOME=/tmp"
  --volume "$REPO_ROOT:/work"
  --workdir /work
)

if [[ "$DRY" == "1" ]]; then
  echo "==> [dry run] docker run ${docker_args[*]} $IMAGE ${cmd[*]}"
  exit 0
fi

if [[ "$mode" == "shell" ]]; then
  exec docker run -it "${docker_args[@]}" --entrypoint /bin/bash "$IMAGE"
fi

exec docker run "${docker_args[@]}" "$IMAGE" "${cmd[@]}"
