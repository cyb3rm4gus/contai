#!/usr/bin/env bash
# cook.sh — detect the host's VSCodium, fetch the matching REH server, build the
# container image, and start it. Run from anywhere:  ./harness/cook.sh
#
# Overrides (rarely needed):
#   VSCODIUM_VERSION=1.126.04524 ./cook.sh   # skip detection, pin a version
#   CODIUM_BIN=/path/to/codium ./cook.sh     # point at a non-PATH install
#   REH_PORT=8000 ./cook.sh                   # change the loopback port
set -euo pipefail
cd "$(dirname "$0")"                 # harness/
ROOT_DIR="$(cd .. && pwd)"           # project root — compose.yml + Dockerfile live here

command -v docker >/dev/null || { echo "ERROR: docker not found on PATH." >&2; exit 1; }
PORT="${REH_PORT:-8000}"

sha256_of() { # portable sha256 -> stdout
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# ---- 1. Locate desktop VSCodium ----
if [ -z "${CODIUM_BIN:-}" ]; then
    for c in codium codium.cmd VSCodium; do
        if command -v "$c" >/dev/null 2>&1; then CODIUM_BIN="$c"; break; fi
    done
fi
if [ -z "${CODIUM_BIN:-}" ] && [ -x "/Applications/VSCodium.app/Contents/Resources/app/bin/codium" ]; then
    CODIUM_BIN="/Applications/VSCodium.app/Contents/Resources/app/bin/codium"
fi

VER="${VSCODIUM_VERSION:-}"
COMMIT="${VSCODIUM_COMMIT:-}"
ARCH_RAW=""
if [ -n "${CODIUM_BIN:-}" ]; then
    VOUT="$("$CODIUM_BIN" --version 2>/dev/null || true)"   # <version>\n<commit>\n<arch>
    [ -n "$VER" ]    || VER="$(printf '%s\n'  "$VOUT" | sed -n '1p')"
    [ -n "$COMMIT" ] || COMMIT="$(printf '%s\n' "$VOUT" | sed -n '2p')"
    ARCH_RAW="$(printf '%s\n' "$VOUT" | sed -n '3p')"
    echo "Detected VSCodium: version=${VER:-?} commit=${COMMIT:-?} arch=${ARCH_RAW:-?}"
else
    echo "NOTE: VSCodium CLI not found on PATH."
fi

if [ -z "$VER" ]; then
    echo "ERROR: could not determine Codium version. Open Codium > About to find it," >&2
    echo "       then re-run:  VSCODIUM_VERSION=<version> ./cook.sh" >&2
    exit 1
fi

# ---- 2. Map arch and fetch the matching REH server ----
case "${ARCH_RAW:-$(uname -m)}" in
    x64|x86_64|amd64) REH_ARCH=x64   ;;
    arm64|aarch64)    REH_ARCH=arm64 ;;
    *) echo "ERROR: unsupported arch '${ARCH_RAW:-$(uname -m)}'." >&2; exit 1 ;;
esac

ASSET="vscodium-reh-linux-${REH_ARCH}-${VER}.tar.gz"
URL="https://github.com/VSCodium/vscodium/releases/download/${VER}/${ASSET}"
mkdir -p reh
if [ ! -f "reh/${ASSET}" ]; then
    echo "Downloading ${URL}"
    curl -fL --retry 3 -o "reh/${ASSET}.part" "$URL"
    mv "reh/${ASSET}.part" "reh/${ASSET}"
fi
cp -f "reh/${ASSET}" reh/reh.tar.gz
SHA="$(sha256_of reh/reh.tar.gz)"
echo "REH asset: ${ASSET}"
echo "REH sha256: ${SHA}"

# ---- 3. Build + start (rebuild only when the container's REH is out of sync) ----
export VSCODIUM_COMMIT="$COMMIT"
CUR_COMMIT="$(docker exec wiki-agent sed -n 's/.*"commit"[: ]*"\([a-f0-9]\{40\}\)".*/\1/p' /opt/codium-reh/product.json 2>/dev/null | head -n1 || true)"
if [ -n "$COMMIT" ] && [ "$CUR_COMMIT" = "$COMMIT" ]; then
    echo "Container REH already matches desktop commit ${COMMIT}; skipping rebuild."
else
    [ -n "$CUR_COMMIT" ] && echo "Codium changed (was ${CUR_COMMIT}, now ${COMMIT}); rebuilding REH layer only..." \
                         || echo "Building image (verifying REH commit matches your desktop)..."
    docker compose -f "$ROOT_DIR/compose.yml" build --build-arg VSCODIUM_COMMIT="$COMMIT"
fi
echo "Starting container..."
REH_PORT="$PORT" docker compose -f "$ROOT_DIR/compose.yml" up -d

# ---- 3b. Build + install our zero-dependency resolver into desktop Codium ----
echo "Building and installing the Wiki REH resolver (zero deps, zip-only build)..."
CODIUM_BIN="${CODIUM_BIN:-}" ./build-resolver.sh

# ---- 4. Show connection details ----
echo "Waiting for the REH server to come up..."
for _ in $(seq 1 30); do
    TOKEN="$(docker exec wiki-agent cat /home/agent/.vscodium-server/connection-token 2>/dev/null || true)"
    [ -n "$TOKEN" ] && break
    sleep 1
done

cat <<EOF

============================================================
 Container is up. VSCodium REH listening on 127.0.0.1:${PORT}
 Resolver 'local.wiki-reh-resolver' installed (built here, zero deps).
============================================================
One-time host setup in VSCodium:
  1. Command Palette > 'Preferences: Configure Runtime Arguments', add:
         "enable-proposed-api": ["local.wiki-reh-resolver"]
     then fully quit and reopen Codium.
  2. Add this to your Codium settings.json:

  "wikiReh.hosts": [
    {
      "name": "wiki-agent",
      "host": "localhost",
      "port": ${PORT},
      "connectionToken": "${TOKEN:-<run: docker exec wiki-agent cat /home/agent/.vscodium-server/connection-token>}",
      "folders": [ { "name": "agent", "path": "/home/agent" } ]
    }
  ]

  3. Command Palette > 'Wiki REH: Connect to Container'.
     The Claude Code sidebar is already installed inside the container.
     Sign in once (web auth); it persists in the agent-home volume.
============================================================
EOF
