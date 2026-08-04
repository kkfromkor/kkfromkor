@echo off
rem ==================================================
rem  OPCG work folder sync (double-click to run)
rem  Actual logic lives in: scripts\sync-opcg.ps1
rem ==================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\sync-opcg.ps1" %*
echo.
pause
