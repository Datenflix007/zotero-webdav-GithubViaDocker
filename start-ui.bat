@echo off
setlocal
cd /d "%~dp0"

title MyLiteratureVault UI
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vault-ui.ps1" -OpenBrowser
pause
