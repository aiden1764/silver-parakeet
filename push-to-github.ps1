<#
.SYNOPSIS
  Push this repo's staged files to GitHub via the Contents API (no git required).

.DESCRIPTION
  One PUT per file, each becoming its own commit. The GitHub Contents API accepts
  UTF-8 text; this script base64-encodes every file itself so no codepage or BOM
  ambiguity can corrupt content. The API adds a trailing newline to base64 input,
  so the read-back comparison is done on trimmed text.

  Intended for a machine without git. Prefer plain `git push` when git exists.

.PARAMETER Owner
  GitHub account. Default: aiden1764

.PARAMETER Repo
  Repository name. Default: silver-parakeet

.PARAMETER Branch
  Target branch. Default: main

.PARAMETER Token
  GitHub PAT with Contents: read and write. Never written to disk.

.PARAMETER Message
  Commit message. Default: chore: sync DSH ponytail skills and global instructions

.PARAMETER DryRun
  List what would be pushed, issue no authenticated requests.

.EXAMPLE
  .\push-to-github.ps1 -Token $env:GH_PAT
  .\push-to-github.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Owner   = 'aiden1764',
    [string]$Repo    = 'silver-parakeet',
    [string]$Branch  = 'main',
    [string]$Token   = $env:GH_PAT,
    [string]$Message = 'chore: sync DSH ponytail skills and global instructions',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

# Files to publish, relative to the repo root. .git is never touched.
$files = @(
    'README.md',
    'install.ps1',
    'install.sh',
    'update.ps1',
    'update.sh',
    'push-to-github.ps1',
    'agents/AGENTS.md',
    'upstream/VERSION.txt',
    'upstream/skills/ponytail/SKILL.md',
    'upstream/skills/ponytail-audit/SKILL.md',
    'upstream/skills/ponytail-debt/SKILL.md',
    'upstream/skills/ponytail-gain/SKILL.md',
    'upstream/skills/ponytail-help/SKILL.md',
    'upstream/skills/ponytail-review/SKILL.md',
    'skills/ponytail/SKILL.md',
    'skills/ponytail-audit/SKILL.md',
    'skills/ponytail-debt/SKILL.md',
    'skills/ponytail-gain/SKILL.md',
    'skills/ponytail-help/SKILL.md',
    'skills/ponytail-review/SKILL.md'
)

$repoRoot = $PSScriptRoot

$present = @()
foreach ($f in $files) {
    $p = Join-Path $repoRoot ($f -replace '/', '\')
    if (Test-Path -LiteralPath $p) {
        $present += [pscustomobject]@{ Rel = $f; Path = $p; Bytes = (Get-Item -LiteralPath $p).Length }
    }
    else {
        Write-Warning "missing, skipped: $f"
    }
}

Write-Host "target : $Owner/$Repo  branch=$Branch"
Write-Host "files  : $($present.Count)"
foreach ($x in $present) { Write-Host ("  {0,-34} {1,6} bytes" -f $x.Rel, $x.Bytes) }
Write-Host ''

if ($DryRun) { Write-Host 'DryRun: no requests issued.'; return }

if (-not $Token) {
    throw 'No token. Pass -Token, or set $env:GH_PAT. Needs Contents: read and write.'
}

$client = [System.Net.Http.HttpClient]::new()
$client.DefaultRequestHeaders.Add('User-Agent', 'dsh-push-script')
$client.DefaultRequestHeaders.Add('Accept', 'application/vnd.github+json')
$client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2022-11-28')
$client.DefaultRequestHeaders.Authorization =
    [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)

# Absolute URI so the relative-URI HttpClient overload is never used: on
# PowerShell 5.1 that overload resolves against .NET Framework, not .NET Core,
# and would silently drop the authorization header.
$base = "https://api.github.com/repos/$Owner/$Repo/contents"

function Invoke-GitHub {
    param([string]$Method, [string]$Uri, [object]$Body)
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $req.Content = [System.Net.Http.StringContent]::new(
            $json, [System.Text.Encoding]::UTF8, 'application/json')
    }
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    return [pscustomobject]@{ Code = [int]$resp.StatusCode; Body = $text }
}

$ok = 0
$failed = @()

foreach ($x in $present) {
    $uri = "$base/$($x.Rel)"

    # Resolve the current blob sha, when the file already exists.
    $sha = $null
    $head = Invoke-GitHub -Method 'GET' -Uri $uri -Body $null
    if ($head.Code -eq 200) {
        $sha = ($head.Body | ConvertFrom-Json).sha
    }
    elseif ($head.Code -ne 404) {
        Write-Warning "$($x.Rel): unexpected probe status $($head.Code)"
    }

    $bytes = [IO.File]::ReadAllBytes($x.Path)
    $payload = [ordered]@{
        message = $Message
        content = [Convert]::ToBase64String($bytes)
        branch  = $Branch
    }
    if ($sha) { $payload['sha'] = $sha }

    $res = Invoke-GitHub -Method 'PUT' -Uri $uri -Body $payload

    if ($res.Code -eq 200 -or $res.Code -eq 201) {
        $action = if ($sha) { 'updated' } else { 'created' }
        Write-Host ("[ok]   {0,-34} {1}" -f $x.Rel, $action)
        $ok++
    }
    else {
        Write-Host ("[FAIL] {0,-34} HTTP {1}: {2}" -f $x.Rel, $res.Code, $res.Body)
        $failed += $x.Rel
    }
}

# Read back and compare so the push is verified, not assumed.
Write-Host ''
Write-Host '--- verification ---'
$mismatch = @()
foreach ($x in $present) {
    $res = Invoke-GitHub -Method 'GET' -Uri "$base/$($x.Rel)" -Body $null
    if ($res.Code -ne 200) {
        Write-Host ("[MISS] {0,-34} HTTP {1}" -f $x.Rel, $res.Code)
        $mismatch += $x.Rel
        continue
    }
    $remote = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String(($res.Body | ConvertFrom-Json).content))
    $local = [IO.File]::ReadAllText($x.Path)
    if ($remote.Trim() -eq $local.Trim()) {
        Write-Host ("[v]    {0,-34} matches" -f $x.Rel)
    }
    else {
        Write-Host ("[DIFF] {0,-34} MISMATCH" -f $x.Rel)
        $mismatch += $x.Rel
    }
}

$client.Dispose()
Write-Host ''
Write-Host "pushed $ok/$($present.Count); mismatches: $($mismatch.Count)"
if ($failed.Count -or $mismatch.Count) {
    Write-Host "problem files: $((@($failed) + @($mismatch) | Select-Object -Unique) -join ', ')"
    exit 1
}
Write-Host "done: https://github.com/$Owner/$Repo"
