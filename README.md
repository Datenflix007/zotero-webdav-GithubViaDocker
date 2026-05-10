# MyLiteratureVault
<img width="1691" height="1278" alt="image" src="https://github.com/user-attachments/assets/8a12c5e2-8550-4cde-a723-f1eb6a4f991f" />

Lokaler WebDAV-Speicher fuer Zotero mit automatischer Synchronisation in dieses GitHub-Repository und einer lokalen Browser-UI zur Verwaltung.

## Schnellstart

### Windows

Doppelklick auf:

```text
quickstart.bat
```

Der Quickstart erledigt automatisch:

1. `.env.local` anlegen (beim ersten Start werden GitHub-Zugangsdaten abgefragt)
2. Docker installieren, falls noch nicht vorhanden
3. Docker starten
4. WebDAV-Container starten
5. Neueste GitHub-Commits pullen
6. Auto-Sync als unsichtbaren Hintergrundprozess starten
7. Browser-UI starten und Browser oeffnen
8. Das Quickstart-Fenster schliesst sich automatisch

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

## Browser-UI

Die UI laeuft unter `http://localhost:8765` und bietet:

### Source Control Graph

Zeigt den Commit-Verlauf als Timeline. Auto-Sync-Statusmeldungen erscheinen farbcodiert zwischen den Commits:

- Gruener Punkt: Erfolgreich (Commit erstellt, Push abgeschlossen)
- Blauer Punkt: Info (Aenderungen erkannt, Fetch)
- Orangener Punkt: Warnung (Pull uebersprungen, Push-Fehler)
- Roter Punkt: Fehler

Der Graph aktualisiert sich alle 5 Sekunden automatisch.

### TODOs

Aufgabenverwaltung direkt in der UI, intern ueber GitHub Issues gespeichert:

- **Neues TODO erstellen**: Schaltflaeche `+ Neues TODO` im Panel, Titel und optionale Beschreibung eingeben
- **Als erledigt markieren**: Auf den Kreis links neben dem TODO klicken (gruen = erledigt)
- **Bearbeiten**: `Bearbeiten`-Schaltflaeche oeffnet Vollansicht mit Titel, Text und Status
- **Erledigte anzeigen/ausblenden**: Checkbox `Erledigte anzeigen` oben rechts im Panel
- Alle TODOs sind auf GitHub unter `Issues` sichtbar und synchronisiert

### Pull Requests

Zeigt offene und geschlossene Pull Requests. Titel, Text und Status koennen bearbeitet werden.

### Aktionen in der Sidebar

| Schaltflaeche    | Funktion                                                      |
|------------------|---------------------------------------------------------------|
| Pull             | Fetch + Pull vom GitHub-Remote                                |
| Commit           | Manuellen Commit erstellen (alle Aenderungen, freier Text)    |
| Settings         | GitHub-Zugangsdaten und WebDAV-Einstellungen aendern          |
| Server stoppen   | UI-Server beenden (danach Seite neu laden zum Wiederverbinden)|

### Sidebar anpassen

- **Breite aendern**: Den vertikalen Trennstrich zwischen Sidebar und Hauptbereich nach links oder rechts ziehen. Die Breite wird gespeichert.
- **Einklappen**: Pfeil-Schaltflaeche oben rechts in der Sidebar

## Manueller Commit

Ueber die `Commit`-Schaltflaeche in der Sidebar koennen alle lokalen Aenderungen mit einer eigenen Nachricht committed werden. Standardtext ist `Manueller Sync [Datum Uhrzeit]`. Optional kann direkt gepusht werden.

## Auto-Sync

Der Auto-Sync laeuft als unsichtbarer Hintergrundprozess und:

- ueberwacht das Verzeichnis `data/` auf Aenderungen
- wartet 10 Sekunden Ruhezeit nach der letzten Aenderung (Debounce)
- erstellt automatisch einen Commit mit Zeitstempel
- pusht zu GitHub (falls Token gesetzt)
- protokolliert alle Aktionen in `.sync-log.json`, die in der UI im Graph angezeigt werden

## Wichtige Dateien

```text
quickstart.bat      Windows-Start per Doppelklick
docker-compose.yml  WebDAV-Container
auto-sync.ps1       Auto-Sync (laeuft als Hintergrundprozess)
vault-ui.ps1        Lokaler HTTP-Server fuer die Browser-UI
ui/                 HTML/CSS/JS der Browser-UI
zotero-plugin/      Zotero-7-Plugin, das die lokale UI in Zotero oeffnet
data/               Zotero-WebDAV-Dateien (werden automatisch synchronisiert)
.env.local          Lokale Zugangsdaten (wird nicht committed)
.sync-log.json      Auto-Sync-Protokoll fuer die UI (wird nicht committed)
```

## Zotero Plugin

Das Plugin zeigt die lokale UI direkt aus Zotero heraus an. Vorher muss die UI laufen (`quickstart.bat`).

Plugin bauen:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-zotero-plugin.ps1
```

In Zotero installieren:

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

- Task-Manager: PowerShell-Prozess mit `auto-sync.ps1` im Befehl beenden

UI-Server stoppen:

- Schaltflaeche `Server stoppen` in der Sidebar der UI
- Oder: Task-Manager: PowerShell-Prozess mit `vault-ui.ps1` im Befehl beenden

## Pruefen

```bash
docker ps
git status
git log --oneline -5
```

## Hinweise

- Der Auto-Sync beobachtet nur `data/`. Andere Projektdateien koennen ueber `Commit` in der UI manuell committed werden.
- Beim Start wird zuerst `git fetch` und bei sauberem Arbeitsbaum `git pull --ff-only` ausgefuehrt.
- TODOs sind GitHub Issues. Ohne gueltigen `GITHUB_TOKEN` in `.env.local` koennen TODOs nicht geladen oder angelegt werden.
- Lock-Dateien von WebDAV werden ueber `.gitignore` ignoriert.
- Wenn der Push fehlschlaegt: GitHub-Token in `Settings` pruefen oder `quickstart.bat` erneut ausfuehren.
