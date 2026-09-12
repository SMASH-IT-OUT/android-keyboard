# Build the FUTO Keyboard APK from the command line and drop it on the Desktop,
# then install it to every phone connected over USB or Wi-Fi. Ported from the
# GT project's android/build.ps1 (its JDK probe, device-naming and multi-device
# push logic are reused verbatim) and adapted for this repo.
#
#   build-android.cmd              unstable DEBUG APK (default) -> Desktop, then
#                                  adb install -r to a connected phone (if any)
#   build-android.cmd -Release     unstable RELEASE APK (minified) instead
#   build-android.cmd -Stable      the "stable" flavor instead of "unstable"
#   build-android.cmd -Playstore   the "playstore" flavor
#   build-android.cmd -NoInstall   build + Desktop copy only, skip adb
#
# The debug build (default) is signed with the checked-in java/shared.keystore,
# so it installs straight onto a phone with no keystore setup. A release build
# uses keystore.properties if present, else falls back to the same shared key
# (see build.gradle) — so it installs too.
#
# #407: to push to SEVERAL devices in one build, copy push-devices.example.txt
# to push-devices.txt (this folder, gitignored) and list each device — a USB
# serial or a wireless host:port. #480: name them in device-names.txt so the
# install log says which phone got the build.
param(
  [switch]$Release,
  [switch]$Stable,
  [switch]$Playstore,
  [switch]$NoInstall
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$repoRoot = Split-Path $scriptDir -Parent

# Run the one-time setup (setup-android.cmd -> setup.ps1) at most once per build,
# in THIS process so it leaves JAVA_HOME / PATH set for the gradle step. setup.ps1
# is re-run-safe (every step checks before acting), so calling it whenever the
# environment looks incomplete - a missing local.properties, no JDK 17+, or a
# Gradle build that failed on a first, un-set-up machine - is cheap and idempotent.
$script:setupRan = $false
function Invoke-SetupOnce {
  param([string]$Reason)
  if ($script:setupRan) { return }
  $setupScript = Join-Path $scriptDir 'setup.ps1'
  if (-not (Test-Path $setupScript)) {
    throw "$Reason and $setupScript was not found - cannot auto-run setup."
  }
  Write-Host "$Reason - running one-time setup (setup-android.cmd) first..." -ForegroundColor Yellow
  & $setupScript
  $script:setupRan = $true
  Write-Host 'Setup complete - continuing the build.' -ForegroundColor Green
}

# local.properties (how Gradle finds the SDK) is created by setup-android.cmd
# -> setup.ps1 and is gitignored, so a fresh clone or a machine that has never
# run setup hits this on its first build. Rather than fail and make the user
# re-launch, run that one-time setup now, in-process, then continue the build.
# setup.ps1 is re-run-safe (every step checks before acting) and, invoked with &
# in THIS process, also leaves JAVA_HOME / PATH set for the gradle step below.
$localProps = Join-Path $repoRoot 'local.properties'
if (-not (Test-Path $localProps)) {
  Invoke-SetupOnce -Reason 'local.properties is missing'
  if (-not (Test-Path $localProps)) {
    throw 'local.properties is still missing after running setup - check the setup output above for the cause, then re-run.'
  }
}

# JAVA_HOME for gradlew. A machine-wide JAVA_HOME pointing at a VALID but OLD
# install (Java 8 is common) sails through a naive "unset or missing" guard and
# hands Gradle a Java 8 JVM. So: verify the inherited JAVA_HOME really is a 17+
# JDK, and rediscover when it isn't.
$needJdk = $true
if ($env:JAVA_HOME) {
  # Do NOT probe with `java.exe -version`: it prints to STDERR, and under this
  # script's $ErrorActionPreference='Stop' the redirected stderr line becomes a
  # terminating NativeCommandError on Windows PowerShell 5.1. Every JDK ships a
  # textual `release` file - JAVA_VERSION="17.0.12" / "1.8.0_471" - which needs
  # no process at all; old versions put the real major after "1.".
  $releaseFile = Join-Path $env:JAVA_HOME 'release'
  if (Test-Path $releaseFile) {
    $m = Select-String -Path $releaseFile -Pattern 'JAVA_VERSION="(\d+)(?:\.(\d+))?' | Select-Object -First 1
    if ($m) {
      $major = [int]$m.Matches[0].Groups[1].Value
      if ($major -eq 1 -and $m.Matches[0].Groups[2].Success) { $major = [int]$m.Matches[0].Groups[2].Value }
      if ($major -ge 17) { $needJdk = $false }
    }
  }
}
function Find-Jdk17 {
  @(Get-ChildItem "$env:ProgramFiles\Microsoft\jdk-*" -Directory -ErrorAction SilentlyContinue) +
  @(Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium\jdk-*" -Directory -ErrorAction SilentlyContinue) |
    Where-Object { $_.Name -match 'jdk-(\d+)' -and [int]$Matches[1] -ge 17 } |
    Sort-Object Name -Descending | Select-Object -First 1
}
if ($needJdk) {
  $jdk = Find-Jdk17
  if (-not $jdk) {
    # No usable JDK on the machine - the environment isn't set up. Run setup
    # (it installs OpenJDK 17) and look again rather than failing.
    Invoke-SetupOnce -Reason 'No JDK 17+ found'
    $jdk = Find-Jdk17
    if (-not $jdk) { throw 'No JDK 17+ found even after running setup - check the setup output above, then re-run.' }
  }
  Write-Host "JAVA_HOME is not a JDK 17+ - using $($jdk.FullName)" -ForegroundColor Yellow
  $env:JAVA_HOME = $jdk.FullName
}
# Chosen JDK first on PATH so gradlew's child processes agree with JAVA_HOME.
$env:Path = "$env:JAVA_HOME\bin;$env:Path"

# The build needs its git submodules (layouts, libs, models, …). If a key one is
# empty, fetch them now so the build does not fail with a cryptic missing-file
# error. setup.ps1 does this too, but a build invoked directly should self-heal.
$needSub = $false
foreach ($p in @('libs', 'java\assets\layouts')) {
  $full = Join-Path $repoRoot $p
  if (-not (Test-Path $full) -or -not (Get-ChildItem $full -Force -ErrorAction SilentlyContinue)) { $needSub = $true }
}
if ($needSub -and (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Host 'Fetching git submodules the build needs...' -ForegroundColor Yellow
  Push-Location $repoRoot
  try {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & git submodule update --init --recursive
    $ErrorActionPreference = $prev
  } finally { Pop-Location }
}

# Flavor + build type -> the assemble<Flavor><BuildType> Gradle task.
$flavor = if ($Stable) { 'Stable' } elseif ($Playstore) { 'Playstore' } else { 'Unstable' }
$buildType = if ($Release) { 'Release' } else { 'Debug' }
$task = "assemble$flavor$buildType"

# Give the APK a meaningful version. build.gradle derives versionCode from
# `git rev-list --first-parent --count master` and versionName from
# `git describe --tags`; with no tags that name is "0.0.0". Set the env vars
# build.gradle honours (VERSION_CODE / VERSION_NAME / BRANCH_NAME) so the file
# on the Desktop names its build and the versionCode climbs with every commit
# (Android only installs an update whose versionCode is >= the installed one).
try {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $count = (& git -C $repoRoot rev-list --first-parent --count master 2>$null | Out-String).Trim()
  if (-not ($count -match '^\d+$')) { $count = (& git -C $repoRoot rev-list --count HEAD 2>$null | Out-String).Trim() }
  $branch = (& git -C $repoRoot branch --show-current 2>$null | Out-String).Trim()
  $hash = (& git -C $repoRoot rev-parse --short HEAD 2>$null | Out-String).Trim()
  $describe = (& git -C $repoRoot describe --tags 2>$null | Out-String).Trim()
  $ErrorActionPreference = $prev
  if ($count -match '^\d+$') { $env:VERSION_CODE = $count }
  if ($branch) { $env:BRANCH_NAME = $branch }
  if ($describe) {
    $env:VERSION_NAME = $describe
  } elseif ($count -match '^\d+$') {
    # No tags in this checkout: build a readable, monotonic-ish name instead.
    $env:VERSION_NAME = "0.0.0-r$count" + $(if ($hash) { "-$hash" } else { '' })
  }
  if ($env:VERSION_NAME) { Write-Host "Version: $($env:VERSION_NAME) (versionCode $($env:VERSION_CODE))" -ForegroundColor Cyan }
} catch {
  Write-Host "Could not derive version from git - the APK keeps build.gradle's fallback." -ForegroundColor Yellow
}

# Force the Python interpreter into UTF-8 mode for the whole build. The
# :updateLocales Gradle task runs tools/make-keyboard-text-py (generate.py),
# which open()s UTF-8 JSON without an explicit encoding; on Windows Python then
# defaults to the legacy cp1252 code page and dies with a UnicodeDecodeError on
# the first non-cp1252 byte (byte 0x81 was the reported case). PYTHONUTF8=1 makes
# open()/stdio default to UTF-8 regardless of the system locale (Python 3.7+),
# which is the correct encoding for that data. Set here so the child gradle -> child
# python inherit it. (generate.py is also fixed at source, but this covers any
# other Python the build shells out to.)
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

# Run the Gradle build, recording success in a SCRIPT-SCOPE flag rather than a
# return value. A function's return value is everything written to its output
# stream, and `& .\gradlew.bat` writes all of Gradle's stdout there - so a
# `return ($LASTEXITCODE -eq 0)` actually returns an array of [gradle output...,
# boolean], which `-not (...)` sees as a non-empty (truthy) collection. That made
# a FAILED build look like it succeeded and fall through to the "no APK" error.
# Reading $script:buildOk sidesteps the capture entirely (the Gradle output just
# goes to the console, which is what we want).
$script:buildOk = $false
function Invoke-GradleBuild {
  Write-Host "Building $task ..." -ForegroundColor Cyan
  Push-Location $repoRoot
  try {
    & .\gradlew.bat $task --console=plain
    $script:buildOk = ($LASTEXITCODE -eq 0)
  } finally {
    Pop-Location
  }
}

Invoke-GradleBuild
if (-not $script:buildOk) {
  # A build can fail because the environment is only partly set up - a missing
  # SDK component (the NDK or CMake the native module needs), an un-fetched
  # submodule, unaccepted licences. If setup hasn't run yet this invocation, run
  # it now (it installs/repairs all of the above, idempotently) and try once
  # more before giving up. If setup already ran, the failure is a real build
  # error, so surface it.
  if ($script:setupRan) {
    throw "Gradle build failed ($task) - setup has already run this build, so this is a build error (see the Gradle output above)."
  }
  Write-Host "Gradle build failed - running setup-android.cmd to repair the environment, then retrying once..." -ForegroundColor Yellow
  Invoke-SetupOnce -Reason 'the build failed and the environment may be incomplete'
  # Re-assert JAVA_HOME/PATH in case setup just installed the JDK.
  $jdk = Find-Jdk17
  if ($jdk) { $env:JAVA_HOME = $jdk.FullName; $env:Path = "$env:JAVA_HOME\bin;$env:Path" }
  Invoke-GradleBuild
  if (-not $script:buildOk) {
    throw "Gradle build still failed ($task) after running setup - see the Gradle output above for the cause."
  }
}

# Find the built APK. The output filename depends on the module's archive base
# name, so glob rather than hard-code it (CI produces latinime-<flavor>-<type>.apk).
$apkDir = Join-Path $repoRoot "build\outputs\apk\$($flavor.ToLower())\$($buildType.ToLower())"
$apk = Get-ChildItem -Path $apkDir -Filter '*.apk' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $apk) { throw "Build reported success but no APK found under $apkDir" }
$apk = $apk.FullName

$versionName = if ($env:VERSION_NAME) { $env:VERSION_NAME } else { $flavor.ToLower() }
$suffix = if ($Release) { '' } else { '-debug' }
$safeName = ($versionName -replace '[^\w.\-]', '_')
$target = Join-Path ([Environment]::GetFolderPath('Desktop')) "FUTO-Keyboard-$safeName$suffix.apk"
Copy-Item $apk $target -Force
Write-Host "APK: $target" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Sideload to whatever phone is plugged in (USB debugging on) or listed in
# push-devices.txt. The whole block below — device naming, multi-device push,
# and per-state diagnostics — is ported from GT's android/build.ps1 (#407/#480).
# ---------------------------------------------------------------------------

# Name map, built from the two config files in THIS folder. Keys may be a whole
# serial or a FRAGMENT of one: a wireless mDNS name embeds the USB serial and
# its trailing -XXXXXX changes on every re-pair, so "R5CRB1FAXLP = Work S21"
# keeps naming that phone after it is paired again.
$deviceNames = [ordered]@{}

# Parse one config line, "<key> = <name>" or a bare key, into the map. Returns
# the key (or $null for blanks and comments) so one parser serves both files.
function Read-DeviceNameLine {
  param([string]$Line)
  $text = $Line.Trim()
  if (-not $text -or $text.StartsWith('#')) { return $null }
  $eq = $text.IndexOf('=')
  if ($eq -lt 0) { return $text }
  $key = $text.Substring(0, $eq).Trim()
  $name = $text.Substring($eq + 1).Trim()
  if ($key -and $name) { $script:deviceNames[$key] = $name }
  if ($key) { return $key }
  return $null
}

# Exact match first, then fragment - see the re-pair note above.
function Resolve-DeviceName {
  param([string]$Serial)
  if (-not $Serial) { return $null }
  foreach ($key in $script:deviceNames.Keys) {
    if ($Serial -eq $key) { return $script:deviceNames[$key] }
  }
  foreach ($key in $script:deviceNames.Keys) {
    if ($Serial.IndexOf($key, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $script:deviceNames[$key] }
  }
  return $null
}

# What the phone calls itself, for devices you never named: the "Device name"
# from Settings > About phone, else the model. Only asked after connect.
function Get-DeviceSelfName {
  param([string]$Adb, [string]$Serial)
  $name = ''
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $name = (& $Adb -s $Serial shell settings get global device_name 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $name -eq 'null') { $name = '' }
    if (-not $name) {
      $name = (& $Adb -s $Serial shell getprop ro.product.model 2>$null | Out-String).Trim()
      if ($LASTEXITCODE -ne 0) { $name = '' }
    }
  } catch {
    $name = ''
  } finally {
    $ErrorActionPreference = $prev
  }
  if (-not $name) { return $null }
  return ($name -split "`n")[0].Trim()
}

# One place decides how a device is printed: "<name>  (<serial>)" when we know
# a name, the bare serial otherwise. -Short drops the serial for summary lines.
function Format-Device {
  param([string]$Serial, [string]$Name, [switch]$Short)
  if (-not $Name) { return $Serial }
  if ($Short) { return $Name }
  return "$Name  ($Serial)"
}

# Name every device once, up front - the self-name probe is an adb round trip.
function Get-DeviceNameMap {
  param([string]$Adb, [string[]]$Serials, [switch]$NoProbe)
  $map = @{}
  foreach ($s in $Serials) {
    $name = Resolve-DeviceName $s
    if (-not $name -and -not $NoProbe) { $name = Get-DeviceSelfName -Adb $Adb -Serial $s }
    $map[$s] = $name
  }
  return $map
}

if (-not $NoInstall) {
  $adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
  if (-not (Test-Path $adb)) {
    $onPath = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($onPath) { $adb = $onPath.Source }
  }
  if (-not (Test-Path $adb)) {
    Write-Host 'adb not found (neither %LOCALAPPDATA%\Android\Sdk\platform-tools nor PATH).' -ForegroundColor Yellow
    Write-Host 'Run setup-android.cmd to install platform-tools, then rebuild.' -ForegroundColor Yellow
  } else {
    # A stale/never-started server is the most common "no devices" cause. No
    # stderr redirection (the NativeCommandError lesson above).
    & $adb start-server | Out-Null

    # #480: the standalone name map is read FIRST, so a name written inline
    # beside a push-devices.txt target wins over an older entry here.
    $nameCfg = Join-Path $scriptDir 'device-names.txt'
    if (Test-Path $nameCfg) {
      foreach ($line in Get-Content $nameCfg) { Read-DeviceNameLine $line | Out-Null }
    }

    # #407: install to EVERY device listed in a gitignored config file.
    $deviceCfg = Join-Path $scriptDir 'push-devices.txt'
    $targets = @()
    if (Test-Path $deviceCfg) {
      $targets = @(Get-Content $deviceCfg | ForEach-Object { Read-DeviceNameLine $_ } | Where-Object { $_ })
    }
    if ($targets.Count -gt 0) {
      # Connect the wireless targets before naming them: the self-name probe is
      # an adb shell call, which only answers once the device is reachable.
      foreach ($t in $targets) { if ($t -match ':\d+$') { & $adb connect $t | Out-Null } }
      $names = Get-DeviceNameMap -Adb $adb -Serials $targets
      $shown = @($targets | ForEach-Object { Format-Device -Serial $_ -Name $names[$_] -Short })
      Write-Host "Installing $versionName to $($targets.Count) configured device(s): $($shown -join ', ')" -ForegroundColor Cyan
      $installed = @()
      $pushed = @()
      $failed = @()
      foreach ($t in $targets) {
        Write-Host "-> $(Format-Device -Serial $t -Name $names[$t])" -ForegroundColor Cyan
        & $adb -s $t install -r $target
        if ($LASTEXITCODE -eq 0) {
          $installed += (Format-Device -Serial $t -Name $names[$t] -Short)
        } else {
          Write-Host "  install failed on $(Format-Device -Serial $t -Name $names[$t]) - pushing the APK to its Download folder instead:" -ForegroundColor Yellow
          & $adb -s $t push $target /sdcard/Download/
          if ($LASTEXITCODE -eq 0) { $pushed += (Format-Device -Serial $t -Name $names[$t] -Short) }
          else { $failed += (Format-Device -Serial $t -Name $names[$t] -Short) }
        }
      }
      if ($installed) { Write-Host "Installed $versionName to: $($installed -join ', ')" -ForegroundColor Green }
      if ($pushed) { Write-Host "APK left in Downloads (open Files > Downloads and tap it) on: $($pushed -join ', ')" -ForegroundColor Yellow }
      if ($failed) {
        Write-Host "Could not reach: $($failed -join ', '). Check each is powered, on the same" -ForegroundColor Yellow
        Write-Host 'network (wireless) or plugged in with USB debugging authorized, then re-run.' -ForegroundColor Yellow
      }
      return
    }

    # Rows are "<serial>`t<state>"; skip the "List of devices" banner.
    $rows = @(& $adb devices) | Where-Object { $_ -match "`t" }
    $ready        = @($rows | Where-Object { $_ -match "`tdevice$" })
    $unauthorized = @($rows | Where-Object { $_ -match "`tunauthorized$" })
    $offline      = @($rows | Where-Object { $_ -match "`toffline$" })
    if ($ready) {
      $serials = @($ready | ForEach-Object { ($_ -split "`t")[0] })
      $names = Get-DeviceNameMap -Adb $adb -Serials $serials
      $shown = @($serials | ForEach-Object { Format-Device -Serial $_ -Name $names[$_] -Short })
      Write-Host "Installing $versionName to $($serials.Count) connected device(s): $($shown -join ', ')" -ForegroundColor Cyan
      $installed = @()
      $pushed = @()
      foreach ($serial in $serials) {
        Write-Host "-> $(Format-Device -Serial $serial -Name $names[$serial])" -ForegroundColor Cyan
        # Target each by serial - a bare `install -r` errors "more than one
        # device" as soon as a second phone is attached.
        & $adb -s $serial install -r $target
        if ($LASTEXITCODE -eq 0) {
          $installed += (Format-Device -Serial $serial -Name $names[$serial] -Short)
        } else {
          Write-Host "  adb install failed (see output above) - pushing the APK to Download instead:" -ForegroundColor Yellow
          & $adb -s $serial push $target /sdcard/Download/
          if ($LASTEXITCODE -eq 0) { $pushed += (Format-Device -Serial $serial -Name $names[$serial] -Short) }
        }
      }
      if ($installed) { Write-Host "Installed $versionName to: $($installed -join ', ')" -ForegroundColor Green }
      if ($pushed) { Write-Host "APK left in Downloads (open Files > Downloads and tap it) on: $($pushed -join ', ')" -ForegroundColor Yellow }
    } elseif ($unauthorized) {
      $shown = @($unauthorized | ForEach-Object { $s = ($_ -split "`t")[0]; Format-Device -Serial $s -Name (Resolve-DeviceName $s) })
      Write-Host "Phone found but UNAUTHORIZED: $($shown -join ', ')" -ForegroundColor Yellow
      Write-Host 'Unlock the phone and tap "Allow" on the "Allow USB debugging?" prompt' -ForegroundColor Yellow
      Write-Host '(tick "Always allow"), then re-run.' -ForegroundColor Yellow
    } elseif ($offline) {
      $shown = @($offline | ForEach-Object { $s = ($_ -split "`t")[0]; Format-Device -Serial $s -Name (Resolve-DeviceName $s) })
      Write-Host "Phone found but OFFLINE: $($shown -join ', ')" -ForegroundColor Yellow
      Write-Host 'Unplug/replug the cable, or run:' -ForegroundColor Yellow
      Write-Host '  adb kill-server && adb start-server' -ForegroundColor Yellow
    } else {
      Write-Host 'No phone detected. Checklist:' -ForegroundColor Yellow
      Write-Host '  1. Developer options > USB debugging is ON.'
      Write-Host '  2. USB mode is "File transfer / MTP", not "Charging only".'
      Write-Host '  3. Try another cable/port (charge-only cables carry no data).'
      Write-Host '  4. If still absent, install the Google USB driver (or the phone'
      Write-Host '     maker''s driver) and check Device Manager for an "ADB" entry.'
      Write-Host 'The APK is on the Desktop - copying it to the phone by any route installs it.'
    }
  }
}
