<#
.SYNOPSIS
  Publishes a plugin version to the WordPress.org SVN repository.

.DESCRIPTION
  - Checks that "Version:" in <Slug>.php, "Stable tag:" in readme.txt and -Version match.
  - Refuses a version that already exists in tags/.
  - Mirrors the committed git tree (git archive, honours export-ignore) into trunk/.
  - Mirrors .wordpress-org/ into assets/ (banners, icons, screenshots).
  - Registers added and deleted files in SVN.
  - With -Commit: copies trunk to tags/<Version> and commits everything in one revision.
  Without -Commit it only prepares the working copy and prints `svn status`.

  Credentials come from the SVN_USERNAME / SVN_PASSWORD environment variables (user scope);
  the password is passed through stdin, never on the command line.

.EXAMPLE
  .\bin\release.ps1 -Slug nimbus-erp-for-woocommerce -Version 1.4.0 -SourceDir C:\laragon\www\nimbus-erp-for-woocommerce
#>
param(
  [Parameter(Mandatory)] [string] $Slug,
  [Parameter(Mandatory)] [string] $Version,
  [Parameter(Mandatory)] [string] $SourceDir,
  [string] $SvnDir = "C:\laragon\svn\$Slug",
  [switch] $Commit
)

$ErrorActionPreference = 'Stop'
$SvnUrl = "https://plugins.svn.wordpress.org/$Slug"

function Stop-Release([string] $Message) { Write-Host "ERROR: $Message" -ForegroundColor Red; exit 1 }

function Invoke-Svn {
  & svn @args
  if ($LASTEXITCODE -ne 0) { Stop-Release "svn $($args[0]) failed (exit $LASTEXITCODE)" }
}

function Invoke-Mirror([string] $From, [string] $To) {
  New-Item -ItemType Directory -Force $To | Out-Null
  robocopy $From $To /MIR /XD .svn /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { Stop-Release "robocopy $From -> $To failed (exit $LASTEXITCODE)" }
}

function Get-EnvValue([string] $Name) {
  $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
  if (-not $value) { $value = [Environment]::GetEnvironmentVariable($Name, 'User') }
  return $value
}

# 1. Versions
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Stop-Release "Version must be X.Y.Z (got '$Version')" }
$SourceDir = (Resolve-Path $SourceDir).Path
$mainFile = Join-Path $SourceDir "$Slug.php"
$readme = Join-Path $SourceDir 'readme.txt'
if (-not (Test-Path $mainFile)) { Stop-Release "Missing $mainFile" }
if (-not (Test-Path $readme)) { Stop-Release "Missing $readme" }

$phpVersion = (Select-String -Path $mainFile -Pattern '^\s*\*?\s*Version:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value
$stableTag = (Select-String -Path $readme -Pattern '^\s*Stable tag:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value
Write-Host "Version: $phpVersion (php) | Stable tag: $stableTag (readme) | requested: $Version"
if ($phpVersion -ne $Version -or $stableTag -ne $Version) { Stop-Release 'Versions do not match' }

# 2. Tag must not exist
& svn ls "$SvnUrl/tags/$Version" *> $null
if ($LASTEXITCODE -eq 0) { Stop-Release "tags/$Version already exists in $SvnUrl" }

# 3. Source tree from git (only committed files, export-ignore respected)
if (-not (Test-Path (Join-Path $SourceDir '.git'))) { Stop-Release "$SourceDir is not a git repository" }
$dirty = git -C $SourceDir status --porcelain
if ($dirty) { Stop-Release "Uncommitted changes in $SourceDir; commit them first:`n$dirty" }
$gitTag = git -C $SourceDir tag --points-at HEAD
if ($gitTag -notcontains "v$Version") { Write-Host "WARNING: HEAD is not tagged v$Version in git" -ForegroundColor Yellow }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "wporg-$Slug-$Version-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$zip = "$tmp.zip"
git -C $SourceDir archive --format=zip -o $zip HEAD
if ($LASTEXITCODE -ne 0) { Stop-Release 'git archive failed' }
Expand-Archive -Path $zip -DestinationPath $tmp
Remove-Item $zip

try {
  # 4. Working copy: trunk and assets in full, tags/ only its top level
  if (Test-Path (Join-Path $SvnDir '.svn')) {
    Invoke-Svn revert -R --quiet $SvnDir
    Invoke-Svn update --quiet $SvnDir
  } else {
    New-Item -ItemType Directory -Force (Split-Path $SvnDir) | Out-Null
    Invoke-Svn checkout --quiet --depth immediates $SvnUrl $SvnDir
  }
  Invoke-Svn update --quiet --set-depth infinity (Join-Path $SvnDir 'trunk') (Join-Path $SvnDir 'assets')
  # A dry run leaves unversioned files behind; revert does not remove them.
  & svn status $SvnDir | Where-Object { $_ -match '^\?\s+(.+)$' } | ForEach-Object { Remove-Item -Recurse -Force $Matches[1] }

  # 5. Mirror trunk and assets
  Invoke-Mirror $tmp (Join-Path $SvnDir 'trunk')
  $assetsSrc = Join-Path $SourceDir '.wordpress-org'
  if (Test-Path $assetsSrc) { Invoke-Mirror $assetsSrc (Join-Path $SvnDir 'assets') }

  # 6. Register added / deleted files
  foreach ($line in (& svn status $SvnDir)) {
    if ($line -match '^\?\s+(.+)$') { Invoke-Svn add --quiet --parents $Matches[1] }
    elseif ($line -match '^!\s+(.+)$') { Invoke-Svn delete --quiet $Matches[1] }
  }
  $mime = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.svg' = 'image/svg+xml' }
  Get-ChildItem (Join-Path $SvnDir 'assets') -File -ErrorAction SilentlyContinue | ForEach-Object {
    $type = $mime[$_.Extension.ToLower()]
    if ($type) { Invoke-Svn propset --quiet svn:mime-type $type $_.FullName }
  }

  Write-Host "`n== svn status ($SvnDir) ==" -ForegroundColor Cyan
  & svn status $SvnDir

  if (-not $Commit) {
    Write-Host "`nDry run: nothing committed. tags/$Version will be created from trunk with -Commit." -ForegroundColor Yellow
    exit 0
  }

  # 7. Tag and commit in a single revision
  $user = Get-EnvValue 'SVN_USERNAME'
  $password = Get-EnvValue 'SVN_PASSWORD'
  if (-not $user -or -not $password) { Stop-Release 'SVN_USERNAME / SVN_PASSWORD are not set' }
  Invoke-Svn copy --quiet (Join-Path $SvnDir 'trunk') (Join-Path $SvnDir "tags\$Version")
  $password | & svn commit $SvnDir -m "Release $Version" --username $user --password-from-stdin --non-interactive --no-auth-cache
  if ($LASTEXITCODE -ne 0) { Stop-Release 'svn commit failed' }
  Write-Host "`nPublished $Slug ${Version}: https://wordpress.org/plugins/$Slug/" -ForegroundColor Green
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
