#!/usr/bin/env bash
# PID 1 of the container: runs the VSCodium REH server so the desktop Codium can
# attach. `docker exec -it wiki-agent claude` still works alongside this.
set -euo pipefail

SERVER_DATA="${HOME}/.vscodium-server"
TOKEN_FILE="${SERVER_DATA}/connection-token"
EXT_DIR="${SERVER_DATA}/extensions"
PORT="${REH_PORT:-8000}"
SERVER=/opt/codium-reh/bin/codium-server

mkdir -p "${SERVER_DATA}" "${EXT_DIR}"

# Persistent connection token (lives in the agent-home volume).
if [ ! -s "${TOKEN_FILE}" ]; then
    ( cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 ) > "${TOKEN_FILE}"
    chmod 600 "${TOKEN_FILE}"
fi

# One-time: install the official Claude Code extension into the volume.
if ! ls -d "${EXT_DIR}"/anthropic.claude-code-* >/dev/null 2>&1; then
    echo "Installing Claude Code extension (Open VSX)..."
    "${SERVER}" --extensions-dir "${EXT_DIR}" --install-extension anthropic.claude-code \
        || echo "WARN: auto-install failed; install 'Claude Code' from the Extensions panel after connecting."
fi

echo "Starting VSCodium REH on 0.0.0.0:${PORT}"
exec "${SERVER}" \
    --host 0.0.0.0 \
    --port "${PORT}" \
    --telemetry-level off \
    --connection-token-file "${TOKEN_FILE}" \
    --server-data-dir "${SERVER_DATA}" \
    --extensions-dir "${EXT_DIR}"
