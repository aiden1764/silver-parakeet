<#
.SYNOPSIS
  Update the locally installed DSH config from the silver-parakeet repo.

.DESCRIPTION
  Version source of truth is upstream/VERSION.txt in the repo, which records the
  upstream DietrichGebert/ponytail commit this package was built from.

  Flow:
    1. Read the local version marker at <DSH_HOME>/.ponytail-config-version
    2. Fetch upstream/VERSION.txt from the repo (public, no token needed)
    3. If the commit matches and -Force is absent, stop: already current
    4. Otherwise download agents/AGENTS.md and every skills/*/SKILL.md, write
       them into <DSH_HOME>, then record the new commit

  DSH_HOME resolution matches resolveDshHome(): -DshHome, $env:DSH_HOME,
  %APPDATA%\ds-xzt\dsh, then ~\.dsh.

  This file is deliberately ASCII-only. Windows PowerShell 5.1 reads BOM-less
  scripts as ANSI, which corrupts non-ASCII text and breaks parsing.

.PARAMETER Owner
  GitHub account holding the package repo. Default: aiden1764

.PARAMETER Repo
  Package repo name. Default: silver-parakeet

.PARAMETER Branch
  Branch to read. Default: main

.PARAMETER Token
  Optional GitHub PAT. The repo is public, so reads work without one. Provide a
  token only to raise the API rate limit, or if the repo later becomes private.

.PARAMETER DshHome
  Explicit DSH data root. Highest precedence.

.PARAMETER Force
  Re-download and reinstall even when the version already matches.

.PARAMETER Quiet
  Only emit a one-line summary. Intended for scheduled runs.

.PARAMETER CheckOnly
  Report whether an update exists, change nothing. Exit 0 if current, 10 if an
  update is available.

.EXAMPLE
  .\update.ps1
  .\update.ps1 -CheckOnly
  .\update.ps1 -Quiet
#>
[CmdletBinding()]
param(
    [string]$Owner   = 'aiden1764',
    [string]$Repo    = 'silver-parakeet',
    [string]$Branch  = 'main',
    [string]$Token   = $env:GH_PAT,
    [string]$DshHome,
    [switch]$Force,
    [switch]$Quiet,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Resolve-DshHome {
    param([string]$Explicit)
    if ($Explicit)      { return $Explicit }
    if ($env:DSH_HOME)  { return $env:DSH_HOME }
    $desktop = Join-Path $env:APPDATA 'ds-xzt\dsh'
    if (Test-Path -LiteralPath $desktop) { return $desktop }
    return (Join-Path $HOME '.dsh')
}

function Write-Info {
    param([string]$Text)
    if (-not $Quiet) { Write-Host $Text }
}

$target     = Resolve-DshHome -Explicit $DshHome
$markerPath = Join-Path $target '.ponytail-config-version'
$versionUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/upstream/VERSION.txt"
$apiBase    = "https://api.github.com/repos/$Owner/$Repo/contents"

$client = [System.Net.Http.HttpClient]::new()
$client.DefaultRequestHeaders.Add('User-Agent', 'dsh-update-script')
$client.DefaultRequestHeaders.Add('Accept', 'application/vnd.github+json')
if ($Token) {
    $client.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
}

# Absolute URIs only: the relative-URI HttpClient overload resolves against .NET
# Framework on PowerShell 5.1 and would silently drop the authorization header.
function Get-RemoteText {
    param([string]$Uri)
    $resp = $client.GetAsync($Uri).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
        throw "GET $Uri -> HTTP $([int]$resp.StatusCode)"
    }
    return $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
}

function Get-RemoteBytes {
    param([string]$Uri)
    $resp = $client.GetAsync($Uri).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
        throw "GET $Uri -> HTTP $([int]$resp.StatusCode)"
    }
    return $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
}

function Get-MarkerCommit {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*commit\s*=\s*(\S+)') { return $Matches[1] }
    }
    return $null
}

# ---- 1. current local version -------------------------------------------
$localCommit = $null
if (Test-Path -LiteralPath $markerPath) {
    $localCommit = Get-MarkerCommit -Text (Get-Content -LiteralPath $markerPath -Raw)
}

Write-Info "DSH_HOME : $target"
Write-Info "local    : $(if ($localCommit) { $localCommit.Substring(0, 12) } else { '(unknown, never updated via this script)' })"

# ---- 2. remote version ---------------------------------------------------
# raw.githubusercontent.com may be blocked on some networks; fall back to the
# Contents API, which is what the earlier install used successfully.
$remoteText = $null
try {
    $remoteText = Get-RemoteText -Uri $versionUrl
}
catch {
    Write-Info "raw host unavailable, falling back to api.github.com"
    $obj = Get-RemoteText -Uri "$apiBase/upstream/VERSION.txt" | ConvertFrom-Json
    $remoteText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($obj.content))
}

$remoteCommit = Get-MarkerCommit -Text $remoteText
if (-not $remoteCommit) { throw 'could not parse a commit id from upstream/VERSION.txt' }

Write-Info "remote   : $($remoteCommit.Substring(0, 12))"

$changed = ($localCommit -ne $remoteCommit)

if (-not $changed -and -not $Force) {
    if ($Quiet) { Write-Host "ponytail config up to date ($($remoteCommit.Substring(0,12)))" }
    else {
        Write-Host ''
        Write-Host 'Already up to date. Use -Force to reinstall anyway.'
    }
    $client.Dispose()
    exit 0
}

if ($CheckOnly) {
    Write-Host "update available: $($localCommit) -> $remoteCommit"
    $client.Dispose()
    exit 10
}

if ($changed) {
    Write-Info ''
    Write-Info 'Update available.'
}
else {
    Write-Info ''
    Write-Info 'Version matches; reinstalling because -Force was given.'
}
Write-Info ''

# ---- 3. discover and fetch files ----------------------------------------
# Only SKILL.md under a one-level skills/<name>/ directory is installed, which
# is exactly what dsh-skill-filesystem discovers. Flat README/scripts in the
# repo are deliberately not installed.
$toInstall = @()

$skillsListing = Get-RemoteText -Uri "$apiBase/skills" | ConvertFrom-Json
foreach ($entry in $skillsListing) {
    if ($entry.type -ne 'dir') { continue }
    $name = $entry.name
    try {
        $fileObj = Get-RemoteText -Uri "$apiBase/skills/$name/SKILL.md" | ConvertFrom-Json
    }
    catch {
        Write-Warning "skipped $name : no SKILL.md"
        continue
    }
    $toInstall += [pscustomobject]@{
        Kind = 'skill'
        Name = $name
        Dest = Join-Path (Join-Path $target 'skills') "$name\SKILL.md"
        Text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fileObj.content))
    }
}

try {
    $agentsObj = Get-RemoteText -Uri "$apiBase/agents/AGENTS.md" | ConvertFrom-Json
    $toInstall += [pscustomobject]@{
        Kind = 'agents'
        Name = 'AGENTS.md'
        Dest = Join-Path $target 'AGENTS.md'
        Text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($agentsObj.content))
    }
}
catch {
    Write-Warning 'agents/AGENTS.md not found in repo; global instructions will not be updated'
}

# ---- 4. install, skipping byte-identical targets -------------------------
$written = 0
$skipped = 0

foreach ($item in $toInstall) {
    # Never clobber a locally customised AGENTS.md without -Force.
    if ($item.Kind -eq 'agents' -and (Test-Path -LiteralPath $item.Dest) -and -not $Force) {
        $existing = [IO.File]::ReadAllText($item.Dest)
        if ($existing.Trim() -ne $item.Text.Trim()) {
            Write-Warning "AGENTS.md differs locally; kept as is. Use -Force to overwrite."
            $skipped++
            continue
        }
    }

    $dir = Split-Path -Parent $item.Dest
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $needsWrite = $true
    if (Test-Path -LiteralPath $item.Dest) {
        $onDisk = [IO.File]::ReadAllText($item.Dest)
        if ($onDisk.Trim() -eq $item.Text.Trim()) { $needsWrite = $false }
    }

    if ($needsWrite) {
        # UTF8 without BOM: skill frontmatter is parsed as YAML and a BOM would
        # become part of the first key.
        [IO.File]::WriteAllText($item.Dest, $item.Text, [Text.UTF8Encoding]::new($false))
        Write-Info ("[ok]   {0,-34} updated" -f $item.Name)
        $written++
    }
    else {
        Write-Info ("[--]   {0,-34} unchanged" -f $item.Name)
        $skipped++
    }
}

# ---- 5. record the new version ------------------------------------------
$stamp = @(
    "# Local record of the installed ponytail config."
    "# Written by update.ps1 and install.ps1. Safe to delete."
    "repo   = $Owner/$Repo"
    "branch = $Branch"
    "commit = $remoteCommit"
    "updated = $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')"
) -join "`r`n"

[IO.File]::WriteAllText($markerPath, $stamp + "`r`n", [Text.UTF8Encoding]::new($false))
Write-Info ''
Write-Info "version marker -> $markerPath"

$client.Dispose()
Write-Host ''
Write-Host "done: $written written, $skipped unchanged (commit $($remoteCommit.Substring(0,12)))"
Write-Host 'DSH watches its skill roots; a new session picks this up. No restart needed.'
