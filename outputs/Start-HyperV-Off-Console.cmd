@echo off
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0HyperV-Off-Console.ps1"
endlocal
