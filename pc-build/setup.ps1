# One-time Windows build-environment setup for FUTO Keyboard — fully
# command-line, no Android Studio. Ported from the GT project's proven
# android/setup.ps1 and adapted for this repo (native NDK/CMake code and git
# submodules; a debug signing key is already checked in as java/shared.keystore,
# so nothing needs generating to build+install to a phone).
#
# Installs, in order, checking before acting so re-runs are safe:
#   1. Microsoft OpenJDK 17 (via winget) — AGP 8.10 / Gradle 8.14 need JDK 17+.
#   2. Android command-line tools -> %LOCALAPPDATA%\Android\Sdk
#   3. SDK licenses + platform-tools, platforms;android-35, build-tools;35.0.0,
#      ndk;28.2.13676358 and cmake;3.22.1 (the native/jni build needs the NDK +
#      CMake; the versions mirror .ci/Dockerfile and build.gradle's ndkVersion).
#      -Emulator adds the emulator and an Android 35 x86_64 system image.
#   4. local.properties in the repo root (how Gradle finds the SDK — no env vars).
#   5. Fetches the git submodules the build needs (layouts, libs, models, …).
#
# Usage:  setup-android.cmd            from the repo root, or
#         setup-android.cmd -Emulator  to also provision the emulator bits.
param(
  [switch]$Emulator
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$repoRoot = Split-Path $scriptDir -Parent
$sdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'

function Write-Step([string]$text) { Write-Host "`n== $text" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. JDK 17+
Write-Step 'JDK 17+'
$javaHome = $null
$jdkDirs = @(Get-ChildItem "$env:ProgramFiles\Microsoft\jdk-*" -Directory -ErrorAction SilentlyContinue) +
           @(Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium\jdk-*" -Directory -ErrorAction SilentlyContinue)
$jdkDirs = $jdkDirs | Where-Object {
  # jdk-17.0.12+7 style names: take major from the leading number
  $_.Name -match 'jdk-(\d+)' -and [int]$Matches[1] -ge 17
} | Sort-Object Name -Descending
if ($jdkDirs) {
  $javaHome = $jdkDirs[0].FullName
  Write-Host "Found JDK: $javaHome"
} else {
  Write-Host 'No JDK 17+ found - installing Microsoft OpenJDK 17 via winget...'
  winget install --id Microsoft.OpenJDK.17 -e --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -ne 0) { throw 'winget could not install Microsoft.OpenJDK.17 - install a JDK 17+ manually, then re-run.' }
  $jdkDirs = Get-ChildItem "$env:ProgramFiles\Microsoft\jdk-17*" -Directory | Sort-Object Name -Descending
  if (-not $jdkDirs) { throw 'JDK installed but not found under Program Files\Microsoft - open a NEW terminal and re-run.' }
  $javaHome = $jdkDirs[0].FullName
}
$env:JAVA_HOME = $javaHome
$env:Path = "$javaHome\bin;$env:Path"

# ------------------------------------------------- 2. Android command-line tools
Write-Step 'Android command-line tools'
$sdkManager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
if (Test-Path $sdkManager) {
  Write-Host "Found sdkmanager: $sdkManager"
} else {
  # Google rotates the build number in this file name; if the download 404s,
  # look up the current "Command line tools only" zip on
  # https://developer.android.com/studio and update the URL here. (This is the
  # same build number .ci/Dockerfile pins for the Linux CI image.)
  $toolsZipUrl = 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip'
  $zipPath = Join-Path $env:TEMP 'fk-android-cmdline-tools.zip'
  Write-Host "Downloading $toolsZipUrl ..."
  Invoke-WebRequest -Uri $toolsZipUrl -OutFile $zipPath
  $extractDir = Join-Path $env:TEMP 'fk-android-cmdline-tools'
  if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
  Expand-Archive -Path $zipPath -DestinationPath $extractDir
  # The zip contains a bare 'cmdline-tools' folder; sdkmanager requires the
  # layout <sdk>\cmdline-tools\latest\... to know which SDK root it manages.
  $latestDir = Join-Path $sdkRoot 'cmdline-tools\latest'
  New-Item -ItemType Directory -Force -Path (Split-Path $latestDir) | Out-Null
  Move-Item (Join-Path $extractDir 'cmdline-tools') $latestDir
  Remove-Item $zipPath -Force
  Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path $sdkManager)) { throw "sdkmanager still missing after extraction ($sdkManager)" }
  Write-Host "Installed sdkmanager: $sdkManager"
}

# ------------------------------------------------------- 3. licenses + packages
Write-Step 'SDK licenses'
# sdkmanager prompts y/N once per unaccepted license; feeding a surplus of
# "y" lines is the documented headless accept and is a no-op when already done.
("y`n" * 30) | & $sdkManager --licenses | Out-Null

Write-Step 'SDK packages (platform, build-tools, NDK, CMake)'
# ndk;28.2.13676358 matches build.gradle's ndkVersion; cmake;3.22.1 matches the
# `cmake_minimum_required(VERSION 3.22)` in native/jni/CMakeLists.txt and is the
# CMake AGP bundles by default. Without both, the native (C/C++) module fails.
$packages = @(
  'platform-tools',
  'platforms;android-35',
  'build-tools;35.0.0',
  'ndk;28.2.13676358',
  'cmake;3.22.1'
)
if ($Emulator) {
  $packages += @('emulator', 'system-images;android-35;google_apis;x86_64')
}
& $sdkManager @packages
if ($LASTEXITCODE -ne 0) { throw 'sdkmanager failed to install packages (see output above).' }

# --------------------------------------------------------- 4. local.properties
Write-Step 'local.properties'
$localProps = Join-Path $repoRoot 'local.properties'
if (Test-Path $localProps) {
  Write-Host "Already present: $localProps"
} else {
  # Forward slashes: java.util.Properties treats backslash as an escape.
  "sdk.dir=$($sdkRoot.Replace('\', '/'))" | Set-Content -Encoding ascii $localProps
  Write-Host "Wrote $localProps"
}

# --------------------------------------------------------- 5. git submodules
Write-Step 'Git submodules'
# The build needs the submodules declared in .gitmodules (keyboard layouts, the
# android-libs .aar dependencies, voice/swipe models, translations, themes,
# large resources). A clone without them fails to build, so fetch them here.
# Some are hosted on gitlab.futo.org / Hugging Face; if one is unreachable the
# update returns non-zero and leaves that folder empty — warn (don't abort the
# whole setup, the JDK/SDK work above still stands) and name what is missing.
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
  Write-Host 'git not found on PATH - install Git for Windows, then run:' -ForegroundColor Yellow
  Write-Host '  git submodule update --init --recursive' -ForegroundColor Yellow
} else {
  Push-Location $repoRoot
  try {
    # Native command stderr must not be redirected under ErrorActionPreference
    # 'Stop' (it escalates to a terminating error on Windows PowerShell 5.1).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git submodule update --init --recursive
    $subOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
  } finally {
    Pop-Location
  }
  # Report which submodule paths are still empty, whatever git's exit code said.
  $subPaths = @(
    'libs',
    'voiceinput-shared/src/main/ml',
    'java/assets/layouts',
    'translations',
    'java/assets/themes',
    'java/res-large',
    'java/assets/futo-swipe'
  )
  $missing = @()
  foreach ($p in $subPaths) {
    $full = Join-Path $repoRoot ($p -replace '/', '\')
    if (-not (Test-Path $full) -or -not (Get-ChildItem $full -Force -ErrorAction SilentlyContinue)) {
      $missing += $p
    }
  }
  if ($missing.Count -eq 0) {
    Write-Host 'All submodules present.'
  } else {
    Write-Host "Some submodules could not be fetched and are still empty:" -ForegroundColor Yellow
    foreach ($m in $missing) { Write-Host "  - $m" -ForegroundColor Yellow }
    Write-Host 'The build needs these. Re-run the setup when you have network access to' -ForegroundColor Yellow
    Write-Host 'gitlab.futo.org / Hugging Face, or fetch them manually with:' -ForegroundColor Yellow
    Write-Host '  git submodule update --init --recursive' -ForegroundColor Yellow
  }
}

# --------------------------------------------------------- signing note
# No keystore is generated: java/shared.keystore is checked in and signs both
# the debug and (when no keystore.properties exists) the release build, so every
# build installs over the last one on your phones without any extra step. Only
# publishing an official release needs a real key + keystore.properties.

Write-Host ''
Write-Host 'FUTO Keyboard build environment ready.' -ForegroundColor Green
Write-Host 'Next: build-android.cmd  (APK lands on your Desktop; installs to a USB/Wi-Fi phone automatically)'
if ($Emulator) { Write-Host '      run-emulator.cmd  (first run creates the "futokbd" virtual device)' }
