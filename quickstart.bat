@echo off
setlocal

title MyLiteratureVault Quickstart
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
    echo PowerShell wurde nicht gefunden. Bitte Windows PowerShell installieren/aktivieren.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0quickstart.ps1"
set EXITCODE=%ERRORLEVEL%

echo.
if not "%EXITCODE%"=="0" (
    echo Quickstart wurde mit Fehlercode %EXITCODE% beendet.
) else (
    echo Quickstart abgeschlossen.
)
pause
exit /b %EXITCODE%
