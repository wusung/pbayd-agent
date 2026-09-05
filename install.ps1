# pbayd-agent one-line installer.
#
#   irm https://raw.githubusercontent.com/wusung/pbayd-agent/main/install.ps1 | iex
#
# Downloads a release zip + its .sha256 from the public repo
# wusung/pbayd-agent, verifies the checksum, and extracts it to
# %USERPROFILE%\pbayd-agent -- same layout and registry\targets.txt
# preserve behavior as pbayd-agent-zip-paste.ps1, but fetched over the
# network instead of pasted as an embedded base64 blob.
#
# Requires the host to reach github.com / raw.githubusercontent.com
# directly (see docs/onelineinstall/spec.md for the air-gapped-downstream
# limitation).
param(
    [string]$Version,
    # No [ValidateSet] here: PowerShell coerces an unbound/$null -Transport to
    # "" before validating, and "" isn't in the set -- ValidateSet then throws
    # even when the caller never passed -Transport at all. Blank is the valid
    # "let Configure-AgentYaml.ps1 pick the default" signal; validate non-blank
    # values by hand instead (see below).
    [string]$Transport,
    [string]$GhRemote,
    [string]$GhPat,
    [string]$GhBranch,
    [string]$Gh2Remote,
    [string]$Gh2Pat,
    [string]$Gh2MyBranch,
    [string]$Gh2PeerBranch,
    [string]$ExecCmd,
    [switch]$SkipConfig,
    # HTTP tunnel self-service token (docs/http-tunnel-portal/spec.md §3.1):
    # if given, opens a browser to log in against this portal and writes the
    # issued register/session tokens to registry\portal_*.txt. Optional --
    # nothing changes when omitted.
    [string]$PortalUrl
)

$ErrorActionPreference = 'Stop'

if ($Transport -and $Transport -notin @('gh', 'gh2', 'real')) {
    throw "invalid -Transport '$Transport' (must be gh, gh2, or real)"
}

$Repo = 'wusung/pbayd-agent'

function Get-ReleaseAssetUrls {
    param([string]$Tag)
    if ($Tag) {
        $base = "https://github.com/$Repo/releases/download/$Tag"
        return @{ Tag = $Tag; Zip = "$base/pbayd-agent.zip"; Sha = "$base/pbayd-agent.zip.sha256" }
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
    $zipAsset = $release.assets | Where-Object { $_.name -eq 'pbayd-agent.zip' }
    $shaAsset = $release.assets | Where-Object { $_.name -eq 'pbayd-agent.zip.sha256' }
    if (-not $zipAsset -or -not $shaAsset) {
        throw "release $($release.tag_name) is missing pbayd-agent.zip or pbayd-agent.zip.sha256"
    }
    return @{ Tag = $release.tag_name; Zip = $zipAsset.browser_download_url; Sha = $shaAsset.browser_download_url }
}

$assets = Get-ReleaseAssetUrls -Tag $Version
Write-Host "pbayd-agent: installing $($assets.Tag)"

$tmpZip = Join-Path $env:TEMP 'pbayd-agent.zip'
$tmpSha = Join-Path $env:TEMP 'pbayd-agent.zip.sha256'
try {
    Invoke-WebRequest -Uri $assets.Zip -OutFile $tmpZip
    Invoke-WebRequest -Uri $assets.Sha -OutFile $tmpSha

    $expected = (Get-Content $tmpSha -Raw).Trim().Split(' ')[0].ToLower()
    $actual = (Get-FileHash -Path $tmpZip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        throw "sha256 mismatch: expected $expected, got $actual"
    }

    $dest = $env:USERPROFILE
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = [IO.Compression.ZipFile]::OpenRead($tmpZip)
    try {
        foreach ($e in $za.Entries) {
            if (-not $e.Name) { continue }
            $p = Join-Path $dest $e.FullName
            New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $p, $true)
        }
    } finally {
        $za.Dispose()
    }
} finally {
    Remove-Item -Path $tmpZip, $tmpSha -ErrorAction SilentlyContinue
}

$tf = "$dest\pbayd-agent\registry\targets.txt"
if (-not (Test-Path $tf)) {
    Set-Content $tf "# host:port allowlist, one per line`n172.20.6.61:22"
    Write-Host 'NOTE: created registry\targets.txt with 172.20.6.61:22'
} else {
    Write-Host "PRESERVED existing registry\targets.txt:"
    Get-Content $tf | ForEach-Object { Write-Host "  $_" }
}

# Interactive/non-interactive agent.yaml setup lives in Configure-AgentYaml.ps1,
# which ships INSIDE the release zip (deploy/make-bootstrap.py FILES list) --
# not here on main. That keeps this shell rarely-changing (public repo, no
# PAT/push access needed to fetch it) while prompt logic/defaults/bug fixes
# ship via ordinary versioned releases. Older releases predating this feature
# simply won't have the file; skip gracefully rather than failing the install.
#
# Launched as a child `powershell -File` (not dot-sourced/`&`-invoked in this
# process): a script FILE on disk is subject to the machine's execution
# policy (default Restricted), unlike this script's own content, which never
# touches disk -- it arrived via `irm | iex`. `-ExecutionPolicy Bypass` here
# scopes to this one child process only, same pattern already used for
# Start-PbaydAgent.ps1 / pbayd-agent.ps1 in DEPLOY.md.
# Which feature(s) to set up. Exec-transport (agent.yaml: gh/gh2/real, for
# clipboard-bridge's own exec/put/get) and HTTP tunnel (browser-login portal,
# a plain data tunnel with no exec-command concept at all) are independent
# features living on unrelated data models (see docs/onelineinstall/spec.md's
# "安裝模式選擇" section) -- asked as a single mode menu rather than either one
# enum value or two disconnected y/N prompts, since "which of these things do
# you want" is the actual question, not two accept/reject questions that
# happen to be askable independently. Skipped entirely (defaults to mode 3,
# both) when the caller already committed to non-interactive/-SkipConfig, or
# already named a -Transport explicitly.
$nonInteractiveInstall = -not [string]::IsNullOrEmpty($GhPat) -or -not [string]::IsNullOrEmpty($Gh2Pat) -or -not [string]::IsNullOrEmpty($env:PBAYD_GH_PAT)
$setupExecTransport = $true
$setupHttpTunnel = $false
if (-not $SkipConfig -and -not $nonInteractiveInstall -and -not $Transport -and -not $PortalUrl) {
    Write-Host 'install mode:'
    Write-Host '  1) exec-transport only  -- clipboard-bridge exec/put/get (gh/gh2/real)'
    Write-Host '  2) HTTP tunnel only     -- browser-login portal, plain data tunnel'
    Write-Host '  3) both'
    $mode = Read-Host -Prompt 'choice [1/2/3]'
    switch ($mode) {
        '1' { $setupExecTransport = $true; $setupHttpTunnel = $false }
        '2' { $setupExecTransport = $false; $setupHttpTunnel = $true }
        default { $setupExecTransport = $true; $setupHttpTunnel = $true }
    }
} elseif (-not $PortalUrl -and -not $SkipConfig -and -not $nonInteractiveInstall) {
    # -Transport was given explicitly but -PortalUrl wasn't: still offer the
    # tunnel half of the mode choice on its own.
    $wantsPortal = Read-Host -Prompt 'also set up HTTP tunnel via browser login? (y/N)'
    $setupHttpTunnel = $wantsPortal -match '^(?i)y'
}

$configScript = "$dest\pbayd-agent\deploy\Configure-AgentYaml.ps1"
if (-not $setupExecTransport) {
    Write-Host 'SKIPPED exec-transport setup (HTTP tunnel only). Copy config\agent.yaml.example to config\agent.yaml manually if you need it later.'
} elseif (Test-Path $configScript) {
    $configArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $configScript, '-InstallRoot', "$dest\pbayd-agent")
    if ($Transport) { $configArgs += @('-Transport', $Transport) }
    if ($GhRemote) { $configArgs += @('-GhRemote', $GhRemote) }
    if ($GhPat) { $configArgs += @('-GhPat', $GhPat) }
    if ($GhBranch) { $configArgs += @('-GhBranch', $GhBranch) }
    if ($Gh2Remote) { $configArgs += @('-Gh2Remote', $Gh2Remote) }
    if ($Gh2Pat) { $configArgs += @('-Gh2Pat', $Gh2Pat) }
    if ($Gh2MyBranch) { $configArgs += @('-Gh2MyBranch', $Gh2MyBranch) }
    if ($Gh2PeerBranch) { $configArgs += @('-Gh2PeerBranch', $Gh2PeerBranch) }
    if ($ExecCmd) { $configArgs += @('-ExecCmd', $ExecCmd) }
    if ($SkipConfig) { $configArgs += '-SkipConfig' }
    & powershell @configArgs
} else {
    Write-Host 'NOTE: this release predates interactive agent.yaml setup; copy config\agent.yaml.example to config\agent.yaml manually.'
}

# HTTP tunnel self-service token request, same "ships inside the zip, run as
# a child process, skip gracefully if the release predates it" pattern as
# Configure-AgentYaml.ps1 above. Runs when -PortalUrl was given non-interactively,
# or when the install-mode menu above selected it -- either way, no further
# question is asked here; everything else (service name, token issuance)
# happens via the browser login itself, per Request-PortalToken.ps1's
# device-flow.
$defaultPortalUrl = 'https://patchbay.jetsion.com'
if (-not $PortalUrl -and $setupHttpTunnel) {
    $PortalUrl = $defaultPortalUrl
}
if ($PortalUrl) {
    $portalScript = "$dest\pbayd-agent\deploy\Request-PortalToken.ps1"
    if (Test-Path $portalScript) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $portalScript `
            -PortalUrl $PortalUrl -InstallRoot "$dest\pbayd-agent"
    } else {
        Write-Host 'NOTE: this release predates the portal device-flow helper; skipping -PortalUrl.'
    }
}

Write-Host "pbayd-agent $($assets.Tag) written to $dest\pbayd-agent"
if (Test-Path "$dest\pbayd-agent\config\agent.yaml") {
    Write-Host 'start now:        powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\pbayd-agent\Start-PbaydAgent.ps1'
    Write-Host 'start on login:   powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\pbayd-agent\pbayd-agent.ps1 service --install'
    Write-Host '  (registers a logon-trigger Scheduled Task, no admin rights needed, and starts it once now too)'
} else {
    Write-Host 'exec-transport (agent.yaml) was not set up -- skip Start-PbaydAgent.ps1, it has nothing to read and will crash-loop.'
    Write-Host '  Re-run this installer and pick mode 1 or 3 later if you need clipboard-bridge exec/put/get.'
}

# HTTP tunnel Server Agent (tools\HttpTunnelAgent.ps1, docs/http-tunnel/spec.md) forwards
# to a local target -- almost always sshd on this same box -- so its whole point falls
# over silently if OpenSSH Server isn't present. Advisory only: never block the install
# on this, since plain pbayd-agent (CBP tunnel / exec/put/get) has no sshd dependency.
$sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $sshdSvc) {
    Write-Host ''
    Write-Host 'NOTE: OpenSSH Server (sshd) not found on this machine.'
    Write-Host '  Required only if you plan to run tools\HttpTunnelAgent.ps1 (HTTP tunnel'
    Write-Host '  Server Agent, docs/http-tunnel/spec.md) to forward to a local sshd target.'
    Write-Host '  Install it with (elevated PowerShell):'
    Write-Host '    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0'
    Write-Host '    Start-Service sshd'
    Write-Host '    Set-Service -Name sshd -StartupType Automatic'
} elseif ($sshdSvc.Status -ne 'Running') {
    Write-Host ''
    Write-Host "NOTE: OpenSSH Server (sshd) is installed but not running (status: $($sshdSvc.Status))."
    Write-Host '  Needed for tools\HttpTunnelAgent.ps1 to have a live target. Start it with:'
    Write-Host '    Start-Service sshd'
} else {
    Write-Host 'OpenSSH Server (sshd): installed and running.'
}
