@echo off
setlocal
cd /d "%~dp0"
rem Одна команда: загрузка основной конфигурации из base-conf (или -ConfigFilesPath) в ИБ и выгрузка .cf подряд (-Step All).
rem С аргументами всё передаётся в скрипт как есть (например: cf.cmd -WhatIf).
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-MainCf.ps1" -Step All
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-MainCf.ps1" %*
)
exit /b %ERRORLEVEL%
