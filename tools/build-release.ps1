<#
.SYNOPSIS
    Builds the AMMDS Mihon extension and repackages it into dist/.

.DESCRIPTION
    Performs the full release step in one command:

      1. loads signingkey.properties and exports the signing environment variables
         (required whenever signingkey.jks exists - the Gradle signing config reads them);
      2. runs :src:all:ammds:assembleRelease and :src:all:ammds:lintRelease;
      3. runs build_store.py, which copies the APK/JAR/icon into dist/ and regenerates
         ammds-store.pb with URLs pointing at this repository.

    Run it from the repository root (or pass -RepoRoot).

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER ReleaseBaseUrl
    Where the artifacts will be hosted. Defaults to raw.githubusercontent.com on branch main.

.PARAMETER SkipLint
    Skip the release lint task (lint must pass before committing changes).

.EXAMPLE
    .\tools\build-release.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$ReleaseBaseUrl = "https://raw.githubusercontent.com/QYG2297248353/AMMDS-Mihon/main/dist",
    [switch]$SkipLint
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path $RepoRoot).Path
Write-Host "repository: $RepoRoot"

# --- signing ---------------------------------------------------------------
$propsFile = Join-Path $RepoRoot "signingkey.properties"
$keyStore = Join-Path $RepoRoot "signingkey.jks"
if (Test-Path $keyStore) {
    if (-not (Test-Path $propsFile)) {
        throw "$keyStore exists but $propsFile is missing; the release signing config needs KEY_STORE_PASSWORD / ALIAS / KEY_PASSWORD"
    }
    $props = ConvertFrom-StringData (Get-Content $propsFile -Raw)
    foreach ($name in @("KEY_STORE_PASSWORD", "ALIAS", "KEY_PASSWORD")) {
        if (-not $props[$name]) { throw "$propsFile does not define $name" }
        Set-Item -Path "env:$name" -Value $props[$name]
    }
    Write-Host "signing: signingkey.jks (alias $($props['ALIAS']))"
} else {
    Write-Warning "signingkey.jks not found - the APK will be signed with the Android debug key, which breaks updates over an installed release"
}

# --- build -----------------------------------------------------------------
$tasks = @(":src:all:ammds:assembleRelease")
if (-not $SkipLint) { $tasks += ":src:all:ammds:lintRelease" }

Push-Location $RepoRoot
try {
    & .\gradlew.bat @tasks --console=plain
    if ($LASTEXITCODE -ne 0) { throw "gradle build failed ($LASTEXITCODE)" }

    # --- package -----------------------------------------------------------
    python .\src\all\ammds\tools\build_store.py --out-dir dist --release-base-url $ReleaseBaseUrl
    if ($LASTEXITCODE -ne 0) { throw "build_store.py failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "done. commit dist/ and push to publish:"
Write-Host "  git add -A; git commit -m 'release: ammds extension'; git push"
