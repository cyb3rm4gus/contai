# build-resolver.ps1 — Windows/PowerShell twin of build-resolver.sh.
# Packages resolver/ into a VSIX using .NET zip (no Microsoft/npm build tooling)
# and installs it into desktop VSCodium. Idempotent.
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

# locate desktop Codium
$CodiumBin = $env:CODIUM_BIN
if (-not $CodiumBin) {
    foreach ($c in @("codium", "codium.cmd", "VSCodium")) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { $CodiumBin = $cmd.Source; break }
    }
}
if (-not $CodiumBin) {
    $lp = Join-Path $env:LOCALAPPDATA "Programs\VSCodium\bin\codium.cmd"
    if (Test-Path $lp) { $CodiumBin = $lp }
}

$Name = "wiki-reh-resolver"
$Publisher = "local"
$pkgPath = "resolver/package.json"
$pkgText = Get-Content -Raw $pkgPath
$Version = ([regex]::Match($pkgText, '"version":\s*"([^"]*)"')).Groups[1].Value
$Out = Join-Path (Get-Location) "$Name-$Version.vsix"

# Align engine with the desktop version (proposed-API safety).
if ($CodiumBin) {
    $Ver = (& $CodiumBin --version 2>$null)[0]
    $mm = ([regex]::Match($Ver, '^(\d+\.\d+)')).Groups[1].Value
    if ($mm) {
        $pkgText = [regex]::Replace($pkgText, '"vscode":\s*"[^"]*"', "`"vscode`": `"^$mm.0`"")
        Set-Content -Path $pkgPath -Value $pkgText -NoNewline
        Write-Host "Pinned resolver engine to ^$mm.0 (matches your Codium)."
    }
}

# Assemble VSIX contents in a temp dir.
$Build = Join-Path ([System.IO.Path]::GetTempPath()) ("vsix-" + [System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force -Path (Join-Path $Build "extension") | Out-Null
Copy-Item "resolver/package.json","resolver/extension.js","resolver/README.md" (Join-Path $Build "extension")

@'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json"/>
  <Default Extension="js" ContentType="application/javascript"/>
  <Default Extension="md" ContentType="text/markdown"/>
  <Default Extension="vsixmanifest" ContentType="text/xml"/>
</Types>
'@ | Set-Content -Path (Join-Path $Build "[Content_Types].xml")

# The schema/IDs here are the VSIX *file format* VSCodium's installer parses —
# format identifiers, not a dependency on any Microsoft service or code.
@"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="$Name" Version="$Version" Publisher="$Publisher"/>
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
"@ | Set-Content -Path (Join-Path $Build "extension.vsixmanifest")

# Zip via .NET, controlling entry paths (forward slashes) and the bracket filename.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $Out) { Remove-Item $Out }
$zip = [System.IO.Compression.ZipFile]::Open($Out, [System.IO.Compression.ZipArchiveMode]::Create)
function Add-VsixEntry($zip, $file, $entry) {
    $e = $zip.CreateEntry($entry)
    $s = $e.Open()
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $s.Write($bytes, 0, $bytes.Length); $s.Close()
}
Add-VsixEntry $zip (Join-Path $Build "[Content_Types].xml")  "[Content_Types].xml"
Add-VsixEntry $zip (Join-Path $Build "extension.vsixmanifest") "extension.vsixmanifest"
Add-VsixEntry $zip (Join-Path $Build "extension/package.json") "extension/package.json"
Add-VsixEntry $zip (Join-Path $Build "extension/extension.js") "extension/extension.js"
Add-VsixEntry $zip (Join-Path $Build "extension/README.md")    "extension/README.md"
$zip.Dispose()
Remove-Item -Recurse -Force $Build
Write-Host "Built $Out"

if ($CodiumBin) {
    & $CodiumBin --install-extension "$Out" --force
    Write-Host "Installed $Name v$Version into desktop Codium."
} else {
    Write-Host "Codium CLI not found. Install manually: codium --install-extension `"$Out`""
}

Write-Host @"

One-time: enable the proposed 'resolvers' API for this extension.
  In Codium: Command Palette > 'Preferences: Configure Runtime Arguments', add:
      "enable-proposed-api": ["$Publisher.$Name"]
  then fully quit and reopen Codium.
"@
