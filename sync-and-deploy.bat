@echo off
rem ==================================================
rem  OPCG sync + deploy to game folders (double-click)
rem  Launcher only - logic: scripts\sync-and-deploy.ps1
rem ==================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\sync-and-deploy.ps1"
if errorlevel 1 (
  echo.
  echo [!] FAILED - copy the messages above and paste them to Claude.
)
echo.
pause
