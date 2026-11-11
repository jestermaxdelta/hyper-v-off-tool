@echo off
rem Hyper-V Off Tool launcher. Keep this file in the same folder as both .ps1 files.
setlocal
if not exist "%~dp0HyperV-Off-Console.ps1" goto missing
if not exist "%~dp0Disable-HyperV-Fully.ps1" goto missing
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0HyperV-Off-Console.ps1"
exit /b 0

:missing
echo.
echo   Hyper-V Off Tool
echo.
echo   Some of the tool files are missing from this folder:
echo   %~dp0
echo.
echo   What to do: right-click the ZIP file, choose "Extract All", then open
echo   Start-HyperV-Off-Console.cmd from the extracted folder.
echo.
pause
exit /b 1
