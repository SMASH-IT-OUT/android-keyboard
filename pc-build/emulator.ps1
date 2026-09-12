# Create (first run) and launch the "futokbd" Android virtual device - CLI only.
#
#   run-emulator.cmd
#
# Needs the emulator packages: setup-android.cmd -Emulator installs them.
# Hypervisor note: with Hyper-V/WSL2 enabled Windows accelerates the emulator
# through WHPX automatically; on machines without Hyper-V install Google's
# AEHD driver instead (sdkmanager "extras;google;Android_Emulator_Hypervisor_Driver",
# then run its silent_install.bat as admin). Without either the emulator runs
# but is unusably slow - a USB phone with build-android.cmd is the primary
# path; the emulator is best-effort.
$ErrorActionPreference = 'Stop'
$sdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$avdManager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\avdmanager.bat'
$emulatorExe = Join-Path $sdkRoot 'emulator\emulator.exe'
$systemImage = 'system-images;android-35;google_apis;x86_64'

if (-not (Test-Path $avdManager)) { throw 'avdmanager missing - run setup-android.cmd first.' }
if (-not (Test-Path $emulatorExe)) { throw 'Emulator not installed - run setup-android.cmd -Emulator first.' }

# JAVA_HOME for avdmanager (a JVM tool like sdkmanager).
if (-not $env:JAVA_HOME -or -not (Test-Path $env:JAVA_HOME)) {
  $jdk = Get-ChildItem "$env:ProgramFiles\Microsoft\jdk-*" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
  if ($jdk) { $env:JAVA_HOME = $jdk.FullName }
}

$existing = & $avdManager list avd -c 2>$null
if ($existing -notcontains 'futokbd') {
  Write-Host 'Creating the "futokbd" virtual device (Pixel 7, Android 35) ...' -ForegroundColor Cyan
  # avdmanager asks "create a custom hardware profile? [no]" - feed the default.
  'no' | & $avdManager create avd -n futokbd -k $systemImage -d pixel_7
  if ($LASTEXITCODE -ne 0) { throw 'avdmanager could not create the AVD (is the system image installed? setup-android.cmd -Emulator).' }
}

Write-Host 'Launching emulator "futokbd" - first boot takes a few minutes.' -ForegroundColor Cyan
Write-Host 'Once booted, build-android.cmd installs the APK to it like a USB phone.'
& $emulatorExe -avd futokbd
