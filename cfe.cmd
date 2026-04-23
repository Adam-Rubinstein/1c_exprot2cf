@echo off
setlocal
cd /d "%~dp0"
rem Одна команда: загрузка ext-ad в ИБ и выгрузка .cfe подряд (-Step All).
rem С аргументами всё передаётся в скрипт как есть (например: cfe.cmd -WhatIf).
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-ExtensionCfe.ps1" -Step All
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-ExtensionCfe.ps1" %*
)
exit /b %ERRORLEVEL%
