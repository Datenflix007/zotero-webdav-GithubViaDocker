@echo off
setlocal
cd /d "%~dp0"

title MyLiteratureVault Status
echo.
echo ========================================
echo MyLiteratureVault Status
echo ========================================
echo.

echo [1] WebDAV Container
docker ps --filter name=zotero-webdav --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
if errorlevel 1 echo Docker ist nicht erreichbar.
echo.

echo [2] WebDAV URL
echo http://localhost:8080
echo Benutzer: zotero
echo Passwort: siehe .env.local oder Standard changeme123
echo.

echo [3] Auto-Sync
powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*auto-sync.ps1*' }; if ($p) { '[OK] Auto-Sync laeuft' } else { '[WARN] Auto-Sync wurde nicht gefunden' }"
echo.

echo [4] UI
powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*vault-ui.ps1*' }; if ($p) { '[OK] UI laeuft: http://localhost:8765' } else { '[WARN] UI wurde nicht gefunden' }"
echo.

echo [5] Git Status
git status --short
echo.

pause
