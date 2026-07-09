# Multi-arch base (Intel/AMD x86-64 and Apple Silicon/ARM build natively).
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl ca-certificates git \
        poppler-utils python3 python3-pip && \
    pip3 install --no-cache-dir --break-system-packages pypdf pdfplumber && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash agent
USER agent
WORKDIR /home/agent

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/agent/.local/bin:${PATH}"

# --- VSCodium Remote Extension Host (REH) server ---
# Kept LAST so a Codium update (new commit) only rebuilds this small layer, not
# the apt/claude layers above. Provided by start.sh from the official VSCodium
# release matching your desktop; baked in => same trust root as your editor.
USER root
ARG VSCODIUM_COMMIT=""
COPY harness/reh/reh.tar.gz /tmp/reh.tar.gz
RUN set -eux; \
    mkdir -p /tmp/reh /opt/codium-reh; \
    tar -xzf /tmp/reh.tar.gz -C /tmp/reh; \
    BIN="$(find /tmp/reh -type f -name codium-server | head -n1)"; \
    ROOT="$(dirname "$(dirname "$BIN")")"; \
    cp -a "$ROOT/." /opt/codium-reh/; \
    rm -rf /tmp/reh /tmp/reh.tar.gz; \
    test -x /opt/codium-reh/bin/codium-server; \
    GOT="$(sed -n 's/.*"commit"[: ]*"\([a-f0-9]\{40\}\)".*/\1/p' /opt/codium-reh/product.json | head -n1)"; \
    echo "REH server commit: ${GOT}"; \
    if [ -n "${VSCODIUM_COMMIT}" ] && [ "${GOT}" != "${VSCODIUM_COMMIT}" ]; then \
        echo "COMMIT MISMATCH: server=${GOT} desktop=${VSCODIUM_COMMIT}" >&2; exit 1; \
    fi

COPY --chmod=0755 harness/start-reh.sh /usr/local/bin/start-reh.sh

USER agent
ENTRYPOINT ["/usr/local/bin/start-reh.sh"]
