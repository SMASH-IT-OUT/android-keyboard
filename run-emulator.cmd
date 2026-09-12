@echo off
title FUTO Keyboard - Android emulator
where pwsh >nul 2>&1
if %errorlevel%==0 (set "PSHOST=pwsh") else (set "PSHOST=powershell")
%PSHOST% -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc-build\emulator.ps1" %*
if errorlevel 1 pause
