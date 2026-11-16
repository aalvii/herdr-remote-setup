@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Herdr Remote Setup

set "HERE=%~dp0"
if not exist "%HERE%setup.ps1" (
  echo [ERROR] setup.ps1 not found next to this launcher.
  pause
  exit /b 2
)

set "HASARGS=0"
if not "%~1"=="" set "HASARGS=1"

if "%HASARGS%"=="1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%setup.ps1" %*
  set "RC=!errorlevel!"
  if "!RC!"=="0" (
    echo.
    echo [OK] Finished.
  ) else (
    echo.
    echo [FAILED] Exit code !RC!. See the log under %%LOCALAPPDATA%%\HerdrSetup\logs
  )
  echo.
  pause
  exit /b !RC!
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%setup-gui.ps1"
set "RC=!errorlevel!"
if not "!RC!"=="0" (
  echo.
  echo [INFO] GUI exited with code !RC!.
  echo.
  pause
)
exit /b !RC!
