@echo off
setlocal
cd /d "%~dp0"
rem Одна команда: загрузка основной конфигурации из src\cf (или -ConfigFilesPath) в ИБ и выгрузка .cf подряд (-Step All).
rem С аргументами всё передаётся в скрипт как есть (например: cf.cmd -WhatIf).
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-MainCf.ps1" -Step All
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-MainCf.ps1" %*
)
if errorlevel 1 (
  echo.
  echo Export failed, ERRORLEVEL=%ERRORLEVEL%. See messages above.
  pause
)
exit /b %ERRORLEVEL%
