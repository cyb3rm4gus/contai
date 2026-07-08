# cook.ps1 — Windows/PowerShell twin of cook.sh.
# Detects the host's VSCodium, fetches the matching REH server, builds the
# container image, and starts it. Run from anywhere:  .\harness\cook.ps1
#
# Overrides (rarely needed):
#   $env:VSCODIUM_VERSION="1.126.04524"; .\cook.ps1   # skip detection, pin version
#   $env:CODIUM_BIN="C:\path\to\codium.cmd"; .\cook.ps1
#   $env:REH_PORT="8000"; .\cook.ps1

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot                 # harness/
$RootDir = Split-Path -Parent $PSScriptRoot      # project root — compose.yml + Dockerfile live here
$Compose = Join-Path $RootDir "compose.yml"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "docker not found on PATH."; exit 1
}
$Port = if ($env:REH_PORT) { $env:REH_PORT } else { "8000" }

# ---- 1. Locate desktop VSCodium ----
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

$Ver     = $env:VSCODIUM_VERSION
$Commit  = $env:VSCODIUM_COMMIT
$ArchRaw = ""
if ($CodiumBin) {
    $vout = @(& $CodiumBin --version 2>$null)   # <version>\n<commit>\n<arch>
    if (-not $Ver)    { $Ver    = $vout[0] }
    if (-not $Commit) { $Commit = $vout[1] }
    $ArchRaw = $vout[2]
    Write-Host "Detected VSCodium: version=$Ver commit=$Commit arch=$ArchRaw"
} else {
    Write-Host "NOTE: VSCodium CLI not found on PATH."
}

if (-not $Ver) {
    Write-Error "Could not determine Codium version. Open Codium > About, then re-run: `$env:VSCODIUM_VERSION='<version>'; .\cook.ps1"
    exit 1
}

# ---- 2. Map arch and fetch the matching REH server ----
if (-not $ArchRaw) { $ArchRaw = $env:PROCESSOR_ARCHITECTURE }
switch -Regex ($ArchRaw) {
    "x64|x86_64|AMD64" { $RehArch = "x64" }
    "arm64|ARM64|aarch64" { $RehArch = "arm64" }
    default { Write-Error "Unsupported arch '$ArchRaw'."; exit 1 }
}

$Asset = "vscodium-reh-linux-$RehArch-$Ver.tar.gz"
$Url   = "https://github.com/VSCodium/vscodium/releases/download/$Ver/$Asset"
New-Item -ItemType Directory -Force -Path "reh" | Out-Null
if (-not (Test-Path "reh/$Asset")) {
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile "reh/$Asset.part"
    Move-Item -Force "reh/$Asset.part" "reh/$Asset"
}
Copy-Item -Force "reh/$Asset" "reh/reh.tar.gz"
$Sha = (Get-FileHash "reh/reh.tar.gz" -Algorithm SHA256).Hash.ToLower()
Write-Host "REH asset: $Asset"
Write-Host "REH sha256: $Sha"

# ---- 3. Build + start (rebuild only when the container's REH is out of sync) ----
$env:VSCODIUM_COMMIT = $Commit
$curCommit = (docker exec wiki-agent sed -n 's/.*"commit"[: ]*"\([a-f0-9]\{40\}\)".*/\1/p' /opt/codium-reh/product.json 2>$null | Select-Object -First 1)
if ($Commit -and ($curCommit -eq $Commit)) {
    Write-Host "Container REH already matches desktop commit $Commit; skipping rebuild."
} else {
    if ($curCommit) { Write-Host "Codium changed (was $curCommit, now $Commit); rebuilding REH layer only..." }
    else { Write-Host "Building image (verifying REH commit matches your desktop)..." }
    docker compose -f $Compose build --build-arg "VSCODIUM_COMMIT=$Commit"
    if ($LASTEXITCODE -ne 0) { Write-Error "docker build failed."; exit 1 }
}
Write-Host "Starting container..."
$env:REH_PORT = $Port
docker compose -f $Compose up -d
if ($LASTEXITCODE -ne 0) { Write-Error "docker up failed."; exit 1 }

# ---- 3b. Build + install our zero-dependency resolver into desktop Codium ----
Write-Host "Building and installing the Wiki REH resolver (zero deps, .NET-zip build)..."
& (Join-Path $PSScriptRoot "build-resolver.ps1")

# ---- 4. Show connection details ----
Write-Host "Waiting for the REH server to come up..."
$Token = ""
foreach ($i in 1..30) {
    $Token = (docker exec wiki-agent cat /home/agent/.vscodium-server/connection-token 2>$null)
    if ($Token) { break }
    Start-Sleep -Seconds 1
}
if (-not $Token) {
    $Token = "<run: docker exec wiki-agent cat /home/agent/.vscodium-server/connection-token>"
}

@"

============================================================
 Container is up. VSCodium REH listening on 127.0.0.1:$Port
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
      "port": $Port,
      "connectionToken": "$Token",
      "folders": [ { "name": "agent", "path": "/home/agent" } ]
    }
  ]

  3. Command Palette > 'Wiki REH: Connect to Container'.
     The Claude Code sidebar is already installed inside the container.
     Sign in once (web auth); it persists in the agent-home volume.
============================================================
"@ | Write-Host
