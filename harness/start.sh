#!/usr/bin/env bash
# start.sh — detect the host's VSCodium, fetch the matching REH server, build and
# start the container, install our resolver, and write the desktop config so
# there is nothing left to paste by hand. Run from anywhere:  ./harness/start.sh
#
# Idempotent: safe to re-run after `docker compose down -v` (the connection token
# regenerates and this refreshes settings.json) or after a VSCodium update (the
# REH layer rebuilds and enable-proposed-api is re-ensured).
#
# Overrides (rarely needed):
#   VSCODIUM_VERSION=1.126.04524 ./start.sh   # skip detection, pin a version
#   CODIUM_BIN=/path/to/codium ./start.sh     # point at a non-PATH install
#   REH_PORT=8000 ./start.sh                   # change the loopback port
set -euo pipefail
cd "$(dirname "$0")"                 # harness/
ROOT_DIR="$(cd .. && pwd)"           # project root — compose.yml + Dockerfile live here

command -v docker >/dev/null || { echo "ERROR: docker not found on PATH." >&2; exit 1; }
PORT="${REH_PORT:-8000}"
PYBIN="$(command -v python3 || command -v python || true)"   # enables auto-config; falls back to printed steps
EXT_ID="local.contai-resolver"

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
    echo "       then re-run:  VSCODIUM_VERSION=<version> ./start.sh" >&2
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
CUR_COMMIT="$(docker exec contai sed -n 's/.*"commit"[: ]*"\([a-f0-9]\{40\}\)".*/\1/p' /opt/codium-reh/product.json 2>/dev/null | head -n1 || true)"
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
echo "Building and installing the contai resolver (zero deps, zip-only build)..."
CODIUM_BIN="${CODIUM_BIN:-}" ./build-resolver.sh

# ---- 4. Fetch the fresh token and write the desktop config ----
echo "Waiting for the REH server to come up..."
TOKEN=""
for _ in $(seq 1 30); do
    TOKEN="$(docker exec contai cat /home/agent/.vscodium-server/connection-token 2>/dev/null || true)"
    [ -n "$TOKEN" ] && break
    sleep 1
done
[ -n "$TOKEN" ] || { echo "ERROR: REH server did not expose a connection token in time." >&2; exit 1; }

if [ -n "$PYBIN" ]; then
    # build-resolver.sh (step 3b) already ensured enable-proposed-api in argv.json;
    # here we (re)write the host entry so a fresh volume / new token just works.
    "$PYBIN" ./host-config.py set-host \
        --name contai --host localhost --port "$PORT" --token "$TOKEN" \
        --folder-name agent --folder-path /home/agent
    cat <<EOF

============================================================
 contai is up. VSCodium REH on 127.0.0.1:${PORT}; desktop is configured.
   • resolver installed        (${EXT_ID})
   • enable-proposed-api set    (argv.json)
   • contai.hosts written       (settings.json, token refreshed)

 If VSCodium is open, FULLY QUIT and reopen it once — argv.json changes only
 take effect on a real restart (not "Reload Window"). Then:
     Command Palette > 'contai: Connect to Container'
 Sign in once (web auth); it persists in the agent-home volume.
============================================================
EOF
else
    # No python on PATH — fall back to the manual instructions.
    cat <<EOF

============================================================
 Container is up. VSCodium REH listening on 127.0.0.1:${PORT}
 Resolver '${EXT_ID}' installed (built here, zero deps).
 (Install python3 to have start.sh write the two files below for you.)
============================================================
One-time host setup in VSCodium:
  1. Command Palette > 'Preferences: Configure Runtime Arguments', add:
         "enable-proposed-api": ["${EXT_ID}"]
     then fully quit and reopen Codium.
  2. Add this to your Codium settings.json:

  "contai.hosts": [
    {
      "name": "contai",
      "host": "localhost",
      "port": ${PORT},
      "connectionToken": "${TOKEN}",
      "folders": [ { "name": "agent", "path": "/home/agent" } ]
    }
  ]

  3. Command Palette > 'contai: Connect to Container'.
     The Claude Code sidebar is already installed inside the container.
     Sign in once (web auth); it persists in the agent-home volume.
============================================================
EOF
fi
