@echo off
setlocal
"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply-now.ps1"
set "result=%ERRORLEVEL%"
echo.
if not "%result%"=="0" echo Apply failed with exit code %result%.
pause
exit /b %result%
