# MyLiteratureVault

Lokaler WebDAV-Speicher fuer Zotero mit automatischer Synchronisation in dieses GitHub-Repository.

## Schnellstart

### Windows

Doppelklick auf:

```text
quickstart.bat
```

### macOS / Linux

```bash
chmod +x quickstart.sh
./quickstart.sh
```

Der Quickstart erledigt automatisch:

1. `.env.local` anlegen, falls sie noch fehlt
2. Docker installieren, falls moeglich und noch nicht vorhanden
3. Docker starten
4. den WebDAV-Container starten
5. neue GitHub-Commits pullen, wenn lokal keine offenen Aenderungen liegen
6. Auto-Sync und die lokale UI starten

Die UI oeffnet sich automatisch unter:

```text
http://localhost:8765
```

## Zotero einstellen

In Zotero:

1. `Einstellungen`
2. `Sync`
3. Datei-Sync auf `WebDAV` stellen
4. Diese Werte eintragen:

```text
URL:      http://localhost:8080
Benutzer: zotero
Passwort: changeme123
```

Wenn du das Passwort in `.env.local` geaendert hast, verwende dort den Wert von `WEBDAV_PASSWORD`.

## Wichtige Dateien

```text
quickstart.bat      Windows-Start per Doppelklick
quickstart.sh       macOS/Linux-Start
docker-compose.yml  WebDAV-Container
auto-sync.ps1       Auto-Sync fuer Windows/PowerShell
auto-sync.sh        Auto-Sync fuer macOS/Linux ohne PowerShell
vault-ui.ps1        lokale Browser-UI fuer Graph, Issues, Pull Requests und Einstellungen
ui/                 HTML/CSS/JS der lokalen UI
zotero-plugin/      Zotero-7-Plugin, das die lokale UI in Zotero oeffnet
check-status.bat    Statuspruefung auf Windows
data/               Zotero-WebDAV-Dateien
.env.local          lokale Zugangsdaten, wird nicht committed
```

## Zotero Plugin

Das Plugin zeigt die lokale UI direkt aus Zotero heraus an. Vorher muss die UI laufen:

```text
quickstart.bat
```

Plugin bauen:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-zotero-plugin.ps1
```

Danach in Zotero installieren:

```text
Tools -> Add-ons -> Zahnrad -> Install Add-on From File...
```

Datei auswaehlen:

```text
dist/myliteraturevault-zotero.xpi
```

## Stoppen

WebDAV stoppen:

```bash
docker compose down
```

Auto-Sync stoppen:

- Windows: Auto-Sync-Fenster schliessen oder `Ctrl+C`
- macOS/Linux: Prozess aus `auto-sync.log`/Terminal beenden oder neu starten

UI stoppen:

- Windows: PowerShell-Prozess `vault-ui.ps1` beenden oder Terminal von `start-ui.bat` schliessen
- macOS/Linux: Prozess `vault-ui.ps1` beenden

## Pruefen

Windows:

```text
check-status.bat
```

Alle Systeme:

```bash
docker ps
docker compose logs -f
git status
git log --oneline -5
```

## Hinweise

- Der Sync beobachtet nur `data/`. Andere Projektdateien werden nicht automatisch committed.
- Beim Start wird zuerst `git fetch` und bei sauberem Arbeitsbaum `git pull --ff-only` ausgefuehrt.
- Die UI kann Issues und Pull Requests lesen und einfache Felder wie Titel, Text und Status aendern.
- Lock-Dateien von WebDAV werden ueber `.gitignore` ignoriert.
- Wenn der Push fehlschlaegt, ist GitHub meist noch nicht angemeldet oder der Remote ist nicht korrekt gesetzt. Danach einfach `quickstart` erneut ausfuehren oder `start-auto-sync.bat` starten.
