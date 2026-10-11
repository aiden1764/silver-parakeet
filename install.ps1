<#
.SYNOPSIS
  Install this repo's skills and global instructions into the local DSH environment.

.DESCRIPTION
  DSH_HOME resolution matches @deepseek-ai/dsh-home-paths resolveDshHome(), highest first:
    1. -DshHome parameter (explicit)
    2. $env:DSH_HOME environment variable
    3. %APPDATA%\ds-xzt\dsh   (DSH desktop app data directory)
    4. ~\.dsh                 (upstream default name)

  Installs:
    agents\AGENTS.md      ->  $DSH_HOME\AGENTS.md
    skills\*\SKILL.md     ->  $DSH_HOME\skills\<name>\SKILL.md

  This file is deliberately ASCII-only. Windows PowerShell 5.1 reads BOM-less
  scripts as ANSI, which corrupts non-ASCII text and breaks parsing.

.PARAMETER DshHome
  Explicit DSH data root. Highest precedence.

.PARAMETER Force
  Overwrite an existing AGENTS.md. Without it, an existing target is kept.

.EXAMPLE
  .\install.ps1
  .\install.ps1 -Force
  .\install.ps1 -DshHome "D:\my-dsh-data"
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Resolve-DshHome {
    param([string]$Explicit)

    if ($Explicit) { return $Explicit }

    if ($env:DSH_HOME) { return $env:DSH_HOME }

    $desktop = Join-Path $env:APPDATA 'ds-xzt\dsh'
    if (Test-Path -LiteralPath $desktop) { return $desktop }

    return (Join-Path $HOME '.dsh')
}

$repoRoot = $PSScriptRoot
$target   = Resolve-DshHome -Explicit $DshHome

Write-Host "DSH_HOME = $target"
Write-Host ''

if (-not (Test-Path -LiteralPath $target)) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Write-Host "created DSH_HOME: $target"
}

# ---- global instructions -------------------------------------------------
$agentsSrc = Join-Path $repoRoot 'agents\AGENTS.md'
$agentsDst = Join-Path $target 'AGENTS.md'

if (-not (Test-Path -LiteralPath $agentsSrc)) {
    Write-Warning "not found: $agentsSrc -- skipping global instructions"
}
elseif ((Test-Path -LiteralPath $agentsDst) -and -not $Force) {
    Write-Warning "already exists: $agentsDst -- kept as is. Use -Force to overwrite."
}
else {
    Copy-Item -LiteralPath $agentsSrc -Destination $agentsDst -Force
    Write-Host "[ok] AGENTS.md -> $agentsDst"
}

# ---- skills --------------------------------------------------------------
$skillsSrcRoot = Join-Path $repoRoot 'skills'
$skillsDstRoot = Join-Path $target 'skills'

if (-not (Test-Path -LiteralPath $skillsSrcRoot)) {
    Write-Warning "not found: $skillsSrcRoot -- skipping skills"
}
else {
    New-Item -ItemType Directory -Force -Path $skillsDstRoot | Out-Null

    $count = 0
    foreach ($dir in Get-ChildItem -LiteralPath $skillsSrcRoot -Directory) {
        $file = Join-Path $dir.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $file)) {
            Write-Warning "skipped $($dir.Name): no SKILL.md in directory"
            continue
        }

        $dstDir = Join-Path $skillsDstRoot $dir.Name
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        Copy-Item -LiteralPath $file -Destination (Join-Path $dstDir 'SKILL.md') -Force
        Write-Host "[ok] skill $($dir.Name)"
        $count++
    }
    Write-Host ''
    Write-Host "installed $count skills into $skillsDstRoot"
}

# ---- version marker ------------------------------------------------------
# Records the upstream commit this package was built from, so update.ps1 can
# tell whether a newer package exists. Parsed from upstream/VERSION.txt.
$versionSrc = Join-Path $repoRoot 'upstream\VERSION.txt'
$markerDst  = Join-Path $target '.ponytail-config-version'

if (Test-Path -LiteralPath $versionSrc) {
    $versionText = Get-Content -LiteralPath $versionSrc -Raw
    $commit = $null
    foreach ($line in ($versionText -split "`r?`n")) {
        if ($line -match '^\s*commit\s*=\s*(\S+)') { $commit = $Matches[1]; break }
    }

    if ($commit) {
        $stamp = @(
            '# Local record of the installed ponytail config.'
            '# Written by install.ps1 and update.ps1. Safe to delete.'
            'repo   = aiden1764/silver-parakeet'
            'branch = main'
            "commit = $commit"
            "updated = $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')"
        ) -join "`r`n"

        [IO.File]::WriteAllText($markerDst, $stamp + "`r`n", [Text.UTF8Encoding]::new($false))
        Write-Host "version marker -> $markerDst (commit $($commit.Substring(0,12)))"
    }
    else {
        Write-Warning "could not parse a commit id from $versionSrc; update.ps1 will treat this as unknown"
    }
}
else {
    Write-Warning "not found: $versionSrc -- update.ps1 will treat this as unknown"
}

Write-Host ''
Write-Host 'Done. Restart DSH or open a new session to pick this up.'
Write-Host 'DSH watches its skill roots, so a new session is usually enough.'
Write-Host "To pull future versions: .\update.ps1"
