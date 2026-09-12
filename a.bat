@echo off
REM Shorthand for build-android.cmd - build the APK and install it to phones.
REM All arguments pass straight through, so `a -Release`, `a -NoInstall`, etc.
REM behave exactly like the full command.
call "%~dp0build-android.cmd" %*
