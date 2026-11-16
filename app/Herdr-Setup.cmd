@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Herdr Remote Setup

set "HERE=%~dp0"
if not exist "%HERE%herdr-setup.ps1" (
  echo [FAILED] herdr-setup.ps1 not found next to this launcher.
  pause
  exit /b 2
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%herdr-setup.ps1" %*
set "RC=!errorlevel!"

echo.
if "!RC!"=="0" (
  echo [OK] Exit code 0.
) else (
  echo [FAILED] Exit code !RC!.
)

rem Pause only for a double-click launch; automation and -SelfTest must not block.
if "%~1"=="" pause
exit /b !RC!
