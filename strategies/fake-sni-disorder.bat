@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" -StrategyId "fake-sni-disorder"
if errorlevel 1 pause
