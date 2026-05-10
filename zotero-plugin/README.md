# MyLiteratureVault Zotero Plugin

Dieses Plugin zeigt die lokale MyLiteratureVault UI in Zotero an.

Voraussetzung:

```text
quickstart.bat
```

muss laufen, damit `http://localhost:8765` erreichbar ist.

Plugin bauen:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-zotero-plugin.ps1
```

Installation in Zotero:

1. `Tools`
2. `Add-ons`
3. Zahnrad
4. `Install Add-on From File...`
5. `dist/myliteraturevault-zotero.xpi` auswaehlen

Danach in Zotero:

```text
View -> MyLiteratureVault oeffnen
```
