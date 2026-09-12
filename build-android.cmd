@echo off
title FUTO Keyboard - build APK
REM Prefer pwsh (PowerShell 7) when installed: Windows PowerShell 5.1 escalates
REM a native command's stderr into a terminating NativeCommandError under
REM ErrorActionPreference=Stop, which pwsh does not. build.ps1 stays compatible
REM with both, but the more forgiving host removes the whole class of difference.
where pwsh >nul 2>&1
if %errorlevel%==0 (set "PSHOST=pwsh") else (set "PSHOST=powershell")
%PSHOST% -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc-build\build.ps1" %*
if errorlevel 1 pause
