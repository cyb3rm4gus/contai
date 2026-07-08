#!/usr/bin/env bash
# build-resolver.sh — package resolver/ into a VSIX using only `zip` (no
# Microsoft/npm tooling) and install it into the desktop VSCodium. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

command -v zip >/dev/null || { echo "ERROR: 'zip' not found. Install it (e.g. apt install zip / brew install zip)." >&2; exit 1; }

# locate desktop Codium (same detection as cook.sh)
CODIUM_BIN="${CODIUM_BIN:-}"
if [ -z "$CODIUM_BIN" ]; then
    for c in codium codium.cmd VSCodium; do
        command -v "$c" >/dev/null 2>&1 && { CODIUM_BIN="$c"; break; }
    done
fi
if [ -z "$CODIUM_BIN" ] && [ -x "/Applications/VSCodium.app/Contents/Resources/app/bin/codium" ]; then
    CODIUM_BIN="/Applications/VSCodium.app/Contents/Resources/app/bin/codium"
fi

NAME=wiki-reh-resolver
PUBLISHER=local
VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' resolver/package.json | head -n1)"
OUT="$(pwd)/${NAME}-${VERSION}.vsix"

# Align the extension's engine with the desktop version (proposed-API safety).
if [ -n "$CODIUM_BIN" ]; then
    VER="$("$CODIUM_BIN" --version 2>/dev/null | sed -n '1p' || true)"
    MM="$(printf '%s' "${VER:-}" | sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p')"
    if [ -n "$MM" ]; then
        sed -i.bak "s/\"vscode\": *\"[^\"]*\"/\"vscode\": \"^${MM}.0\"/" resolver/package.json
        rm -f resolver/package.json.bak
        echo "Pinned resolver engine to ^${MM}.0 (matches your Codium)."
    fi
fi

# Assemble the VSIX (OPC/zip: [Content_Types].xml + extension.vsixmanifest + extension/).
BUILD="$(mktemp -d)"
mkdir -p "$BUILD/extension"
cp resolver/package.json resolver/extension.js resolver/README.md "$BUILD/extension/"

cat > "$BUILD/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json"/>
  <Default Extension="js" ContentType="application/javascript"/>
  <Default Extension="md" ContentType="text/markdown"/>
  <Default Extension="vsixmanifest" ContentType="text/xml"/>
</Types>
XML

# NOTE: the schema/IDs below (schemas.microsoft.com, Microsoft.VisualStudio.Code)
# are the VSIX *file format* that VSCodium's own installer parses. They are format
# identifiers, not a dependency on any Microsoft service, code, or network call.
cat > "$BUILD/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="${NAME}" Version="${VERSION}" Publisher="${PUBLISHER}"/>
    <DisplayName>Contained claude for wiki and dev</DisplayName>
    <Description>Minimal remote authority resolver for the wiki-agent container.</Description>
    <Tags>remote</Tags>
    <Categories>Other</Categories>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
XML

rm -f "$OUT"
( cd "$BUILD" && zip -r -q "$OUT" '[Content_Types].xml' extension.vsixmanifest extension )
rm -rf "$BUILD"
echo "Built ${OUT}"

# Install into the desktop editor.
if [ -n "$CODIUM_BIN" ]; then
    "$CODIUM_BIN" --install-extension "$OUT" --force
    echo "Installed ${NAME} v${VERSION} into desktop Codium."
else
    echo "Codium CLI not found. Install manually: codium --install-extension \"${OUT}\""
fi

cat <<EOF

One-time: enable the proposed 'resolvers' API for this extension.
  In Codium: Command Palette > 'Preferences: Configure Runtime Arguments', add:
      "enable-proposed-api": ["${PUBLISHER}.${NAME}"]
  then fully quit and reopen Codium.
EOF
