@echo off
REM Shorthand for build-android.cmd that PULLS THE LATEST CODE FIRST, then builds
REM the APK and installs it to your phones. All arguments pass straight through,
REM so `a -Release`, `a -NoInstall`, etc. behave like build-android.cmd.
REM
REM The pull is best-effort: if it fails (offline, or you have local changes /
REM conflicts) the build still runs against the current checkout instead of
REM stopping. Use build-android.cmd directly to build WITHOUT pulling.
pushd "%~dp0"
echo Pulling latest changes (git pull)...
git pull
if errorlevel 1 echo   git pull did not complete (offline, or local changes/conflicts) - building the current checkout anyway.
popd
call "%~dp0build-android.cmd" %*
