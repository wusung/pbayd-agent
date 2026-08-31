# clipd-agent one-line installer.
#
#   irm https://raw.githubusercontent.com/wusung/clipd-agent/main/install.ps1 | iex
#
# Downloads a release zip + its .sha256 from the public repo
# wusung/clipd-agent, verifies the checksum, and extracts it to
# %USERPROFILE%\clipd-agent -- same layout and registry\targets.txt
# preserve behavior as clipd-agent-zip-paste.ps1, but fetched over the
# network instead of pasted as an embedded base64 blob.
#
# Requires the host to reach github.com / raw.githubusercontent.com
# directly (see docs/onelineinstall/spec.md for the air-gapped-downstream
# limitation).
param(
    [string]$Version
)

$ErrorActionPreference = 'Stop'

$Repo = 'wusung/clipd-agent'

function Get-ReleaseAssetUrls {
    param([string]$Tag)
    if ($Tag) {
        $base = "https://github.com/$Repo/releases/download/$Tag"
        return @{ Tag = $Tag; Zip = "$base/clipd-agent.zip"; Sha = "$base/clipd-agent.zip.sha256" }
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
    $zipAsset = $release.assets | Where-Object { $_.name -eq 'clipd-agent.zip' }
    $shaAsset = $release.assets | Where-Object { $_.name -eq 'clipd-agent.zip.sha256' }
    if (-not $zipAsset -or -not $shaAsset) {
        throw "release $($release.tag_name) is missing clipd-agent.zip or clipd-agent.zip.sha256"
    }
    return @{ Tag = $release.tag_name; Zip = $zipAsset.browser_download_url; Sha = $shaAsset.browser_download_url }
}

$assets = Get-ReleaseAssetUrls -Tag $Version
Write-Host "clipd-agent: installing $($assets.Tag)"

$tmpZip = Join-Path $env:TEMP 'clipd-agent.zip'
$tmpSha = Join-Path $env:TEMP 'clipd-agent.zip.sha256'
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

$tf = "$dest\clipd-agent\registry\targets.txt"
if (-not (Test-Path $tf)) {
    Set-Content $tf "# host:port allowlist, one per line`n172.20.6.61:22"
    Write-Host 'NOTE: created registry\targets.txt with 172.20.6.61:22'
} else {
    Write-Host "PRESERVED existing registry\targets.txt:"
    Get-Content $tf | ForEach-Object { Write-Host "  $_" }
}

Write-Host "clipd-agent $($assets.Tag) written to $dest\clipd-agent"
Write-Host 'start now:        powershell -ExecutionPolicy Bypass -File %USERPROFILE%\clipd-agent\Start-ClipdAgent.ps1'
Write-Host 'start on login:   powershell -ExecutionPolicy Bypass -File %USERPROFILE%\clipd-agent\clipd-agent.ps1 service --install'
Write-Host '  (registers a logon-trigger Scheduled Task, no admin rights needed, and starts it once now too)'
