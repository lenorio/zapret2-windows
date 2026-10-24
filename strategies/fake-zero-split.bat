@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" -StrategyId "fake-zero-split"
if errorlevel 1 pause
