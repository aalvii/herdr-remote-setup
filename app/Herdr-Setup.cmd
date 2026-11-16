@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Herdr Connect

set "HERE=%~dp0"
if not exist "%HERE%herdr-connect.ps1" (
  echo [FAILED] herdr-connect.ps1 not found next to this launcher.
  pause
  exit /b 2
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%herdr-connect.ps1" %*
set "RC=!errorlevel!"

echo.
if "!RC!"=="0" (
  echo [OK] Exit code 0.
) else (
  echo [FAILED] Exit code !RC!.
)

if "%~1"=="" pause
exit /b !RC!
