@echo off
rem ==================================================
rem  OPCG sync + deploy to game folders (double-click)
rem  Actual logic lives in: scripts\deploy-opcg.ps1
rem ==================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\deploy-opcg.ps1" %*
if errorlevel 1 (
  echo.
  echo [!] FAILED - copy the messages above and paste them to Claude.
)
echo.
pause
