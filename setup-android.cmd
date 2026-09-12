@echo off
title FUTO Keyboard - one-time Windows build-environment setup
where pwsh >nul 2>&1
if %errorlevel%==0 (set "PSHOST=pwsh") else (set "PSHOST=powershell")
%PSHOST% -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc-build\setup.ps1" %*
if errorlevel 1 pause
