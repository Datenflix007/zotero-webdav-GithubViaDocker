@echo off
setlocal
cd /d "%~dp0"

title MyLiteratureVault Auto-Sync
echo Starte Auto-Sync fuer Zotero WebDAV Daten...
echo Beenden mit Ctrl+C oder Fenster schliessen.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto-sync.ps1" -WatchPath "%~dp0data" -Push
pause
