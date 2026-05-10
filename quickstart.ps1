param(
    [switch]$SkipDockerInstall,
    [switch]$SkipZoteroInstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir
$script:FirstRun = $false

# ----------- Helpers -------------------------------------------------

function Write-Step($Text) {
    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
}
function Write-Ok($Text)   { Write-Host "[OK]   $Text" -ForegroundColor Green  }
function Write-Info($Text) { Write-Host "[INFO] $Text" -ForegroundColor Gray   }
function Write-Warn($Text) { Write-Host "[WARN] $Text" -ForegroundColor Yellow }

# ----------- Env file ------------------------------------------------

function Import-EnvFile {
    $values = [ordered]@{}
    if (-not (Test-Path ".env.local")) { return $values }
    Get-Content ".env.local" | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $key, $value = $line.Split("=", 2)
            $values[$key.Trim()] = $value.Trim()
            [Environment]::SetEnvironmentVariable($key.Trim(), $value.Trim(), "Process")
        }
    }
    return $values
}

function Ensure-EnvFile {
    Write-Step "[1/7] Projekt einrichten"

    if (Test-Path ".env.local") {
        Write-Ok ".env.local ist vorhanden"
        Import-EnvFile | Out-Null
        return
    }

    $script:FirstRun = $true
    Write-Host "Erster Start - bitte GitHub-Daten eingeben."
    $githubUser  = Read-Host "GitHub Benutzername"
    $githubEmail = Read-Host "GitHub E-Mail"
    $githubToken = Read-Host "GitHub Personal Access Token (leer = Git bereits angemeldet)"

    $lines = @(
        "# GitHub Configuration",
        "GITHUB_USERNAME=$githubUser",
        "GITHUB_EMAIL=$githubEmail",
        "GITHUB_TOKEN=$githubToken",
        "",
        "# WebDAV Server",
        "WEBDAV_URL=http://localhost:8080",
        "WEBDAV_USERNAME=zotero",
        "WEBDAV_PASSWORD=changeme123"
    )
    $lines | Out-File -FilePath '.env.local' -Encoding UTF8 -Force

    [Environment]::SetEnvironmentVariable("GITHUB_USERNAME", $githubUser,  "Process")
    [Environment]::SetEnvironmentVariable("GITHUB_EMAIL",    $githubEmail, "Process")
    [Environment]::SetEnvironmentVariable("GITHUB_TOKEN",    $githubToken, "Process")
    if ($githubUser)  { git config user.name  $githubUser  | Out-Null }
    if ($githubEmail) { git config user.email $githubEmail | Out-Null }
    Write-Ok ".env.local erstellt und Git-Benutzer gesetzt"
}

# ----------- Git pull ------------------------------------------------

function Invoke-GitRemotePull {
    Write-Step "[2/7] GitHub-Stand pruefen"

    $token = $env:GITHUB_TOKEN
    $auth = if ($token) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
        @("-c", "http.https://github.com/.extraheader=AUTHORIZATION: basic $b64")
    } else { @() }

    $null = & git @auth fetch --prune 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Fetch fehlgeschlagen - arbeite lokal weiter."
        return
    }

    $dirty = git status --porcelain 2>$null
    if (-not [string]::IsNullOrWhiteSpace($dirty)) {
        Write-Info "Pull uebersprungen (lokale Aenderungen vorhanden)."
        return
    }

    $null = & git @auth pull --ff-only 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "Repository ist aktuell" }
    else { Write-Warn "Fast-forward Pull nicht moeglich - bitte git status pruefen." }
}

# ----------- Zotero --------------------------------------------------

function Find-ZoteroExe {
    $candidates = @(
        "$env:ProgramFiles\Zotero\zotero.exe",
        "${env:ProgramFiles(x86)}\Zotero\zotero.exe",
        "$env:LOCALAPPDATA\Zotero\zotero.exe",
        "$env:LOCALAPPDATA\Programs\Zotero\zotero.exe"
    )
    foreach ($rp in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\zotero.exe",
                      "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\zotero.exe")) {
        $entry = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
        if ($entry -and $entry.'(default)') { $candidates += $entry.'(default)' }
    }
    return ($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

function Ensure-ZoteroInstalled {
    Write-Step "[3/7] Zotero pruefen"

    if (Find-ZoteroExe) {
        Write-Ok "Zotero ist installiert"
        return
    }

    if ($SkipZoteroInstall) {
        Write-Warn "Zotero nicht installiert. Bitte manuell installieren: https://www.zotero.org/download/"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "winget nicht gefunden. Bitte Zotero manuell installieren: https://www.zotero.org/download/"
        return
    }

    $wl = winget list --id Zotero.Zotero --accept-source-agreements 2>&1
    if ($LASTEXITCODE -eq 0 -and "$wl" -match "Zotero") {
        Write-Ok "Zotero ist bereits installiert (winget)"
        return
    }

    Write-Info "Installiere Zotero via winget..."
    winget install --exact --id Zotero.Zotero --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Zotero-Installation fehlgeschlagen. Manuell: https://www.zotero.org/download/"
        return
    }
    Write-Ok "Zotero installiert"
}

function Start-Zotero {
    $running = Get-Process -Name "zotero" -ErrorAction SilentlyContinue
    if ($running) { Write-Ok "Zotero laeuft bereits"; return }

    $exe = Find-ZoteroExe
    if ($exe) {
        Write-Info "Starte Zotero..."
        Start-Process -FilePath $exe -ErrorAction SilentlyContinue
    } else {
        Write-Warn "Zotero nicht gefunden - bitte manuell starten."
    }
}

# ----------- Docker install ------------------------------------------

function Ensure-DockerInstalled {
    Write-Step "[4/7] Docker pruefen"

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Ok "Docker CLI ist vorhanden"
        return
    }

    if ($SkipDockerInstall) {
        throw "Docker nicht installiert. Bitte Docker Desktop installieren: https://www.docker.com/products/docker-desktop/"
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Docker nicht installiert und winget nicht gefunden. Bitte Docker Desktop manuell installieren."
    }

    Write-Info "Installiere Docker Desktop via winget (kann einige Minuten dauern)..."
    winget install --exact --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Docker-Installation fehlgeschlagen. Bitte Docker Desktop manuell installieren: https://www.docker.com/products/docker-desktop/"
    }

    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker installiert, aber noch nicht im PATH. Bitte Windows neu starten und quickstart.bat erneut ausfuehren."
    }
    Write-Ok "Docker Desktop installiert"
}

# ----------- Docker start --------------------------------------------

function Find-DockerDesktopExe {
    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($rp in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Docker Desktop.exe",
                      "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Docker Desktop.exe")) {
        $entry = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
        if ($entry -and $entry.'(default)') { $candidates += $entry.'(default)' }
    }
    return ($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

function Test-DockerReady {
    $null = docker info 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Start-DockerDesktop {
    Write-Step "[5/7] Docker starten"

    if (Test-DockerReady) {
        Write-Ok "Docker Engine laeuft bereits"
        return
    }

    $ddExe = Find-DockerDesktopExe
    if ($ddExe) {
        Write-Info "Starte Docker Desktop: $ddExe"
        Start-Process -FilePath $ddExe -WindowStyle Hidden -ErrorAction SilentlyContinue
    } else {
        Write-Warn "Docker Desktop Exe nicht gefunden - versuche trotzdem..."
        Start-Process "Docker Desktop" -ErrorAction SilentlyContinue
    }

    Write-Host "Warte auf Docker Engine" -NoNewline
    $deadline = (Get-Date).AddMinutes(4)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        Write-Host "." -NoNewline
        if (Test-DockerReady) {
            Write-Host " bereit"
            Write-Ok "Docker Engine ist bereit"
            return
        }
    }

    Write-Host ""
    throw "Docker Engine war nach 4 Minuten nicht bereit. Docker Desktop manuell oeffnen, dann quickstart.bat erneut starten."
}

# ----------- WebDAV --------------------------------------------------

function Test-WebDavReady {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        return ($r.StatusCode -in @(200, 401, 207))
    } catch {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            return ($code -in @(200, 401, 207))
        }
        return $false
    }
}

function Start-WebDav {
    Write-Step "[6/7] WebDAV Container starten"

    if (-not (Test-Path "data")) {
        New-Item -ItemType Directory -Path "data" | Out-Null
        Write-Info "Verzeichnis 'data' erstellt"
    }

    $null = docker compose version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose nicht verfuegbar. Bitte Docker Desktop aktualisieren."
    }

    if (Test-WebDavReady) {
        Write-Ok "WebDAV antwortet bereits auf http://localhost:8080"
        return
    }

    Write-Info "Starte WebDAV Container..."
    $upOut = docker compose up -d 2>&1
    if ($LASTEXITCODE -ne 0) {
        $upOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        docker compose logs --tail 20 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        throw "WebDAV Container konnte nicht gestartet werden."
    }

    Write-Host "Warte auf WebDAV" -NoNewline
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Test-WebDavReady) { Write-Host " OK"; break }
        Start-Sleep -Seconds 2
        Write-Host "." -NoNewline
    }
    Write-Host ""

    $fmt = "  {{.Names}} | {{.Status}} | {{.Ports}}"
    docker ps --filter "name=zotero-webdav" --format $fmt 2>&1 |
        Where-Object { $_ } | ForEach-Object { Write-Info $_ }
    Write-Ok "WebDAV laeuft auf http://localhost:8080"
}

# ----------- Auto-Sync -----------------------------------------------

function Start-AutoSync {
    Write-Step "[7/7] Auto-Sync und UI starten"

    $syncScript = Join-Path $ScriptDir "auto-sync.ps1"
    if (-not (Test-Path $syncScript)) {
        Write-Warn "auto-sync.ps1 nicht gefunden."
        return
    }

    $existing = Get-CimInstance Win32_Process -Filter "name = 'powershell.exe' or name = 'pwsh.exe'" |
        Where-Object { $_.CommandLine -like "*auto-sync.ps1*" -and $_.CommandLine -like "*$ScriptDir*" }

    if ($existing) {
        Write-Ok "Auto-Sync laeuft bereits (PID $($existing.ProcessId))"
        return
    }

    Start-Process powershell -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$syncScript`"",
        "-WatchPath", "`"$ScriptDir\data`"",
        "-Push"
    ) -WindowStyle Hidden

    Write-Ok "Auto-Sync gestartet (Hintergrundprozess)"
}

# ----------- Vault UI ------------------------------------------------

function Start-VaultUi {
    $uiScript = Join-Path $ScriptDir "vault-ui.ps1"
    if (-not (Test-Path $uiScript)) {
        Write-Warn "vault-ui.ps1 nicht gefunden."
        return
    }

    $existing = Get-CimInstance Win32_Process -Filter "name = 'powershell.exe' or name = 'pwsh.exe'" |
        Where-Object { $_.CommandLine -like "*vault-ui.ps1*" -and $_.CommandLine -like "*$ScriptDir*" }

    if ($existing) {
        Write-Ok "UI laeuft bereits auf http://localhost:8765"
        Start-Process "http://localhost:8765"
        return
    }

    Start-Process powershell -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$uiScript`"",
        "-OpenBrowser"
    ) -WindowStyle Hidden
    Write-Ok "UI gestartet: http://localhost:8765"
}

# ----------- Main ----------------------------------------------------

Clear-Host
Write-Host "==========================================" -ForegroundColor Blue
Write-Host " MyLiteratureVault Quickstart             " -ForegroundColor Blue
Write-Host "==========================================" -ForegroundColor Blue

try {
    Ensure-EnvFile
    Invoke-GitRemotePull
    Ensure-ZoteroInstalled
    Ensure-DockerInstalled
    Start-DockerDesktop
    Start-WebDav
    Start-AutoSync
    Start-VaultUi
    Start-Zotero
}
catch {
    Write-Host ""
    Write-Host "[FEHLER] $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Druecke Enter zum Schliessen..." -ForegroundColor DarkGray
    Read-Host | Out-Null
    exit 1
}

Write-Host ""
Write-Host "Fertig! Alle Dienste laufen." -ForegroundColor Green
Write-Host ""
Write-Host "  WebDAV:  http://localhost:8080   Benutzer: zotero   Passwort: changeme123"
Write-Host "  UI:      http://localhost:8765"
Write-Host ""

if ($script:FirstRun) {
    Write-Host "ZOTERO EINRICHTEN (Erster Start):" -ForegroundColor Yellow
    Write-Host "  1. Zotero wurde gestartet - melde dich an oder registriere dich:"
    Write-Host "     https://www.zotero.org/user/login"
    Write-Host ""
    Write-Host "  2. In Zotero: Bearbeiten -> Einstellungen -> Sync -> Datei-Sync"
    Write-Host "     Methode:   WebDAV"
    Write-Host "     URL:       http://localhost:8080"
    Write-Host "     Benutzer:  zotero"
    Write-Host "     Passwort:  changeme123"
    Write-Host "     Dann: 'Server pruefen' klicken"
    Write-Host ""
    Write-Host "Druecke Enter, wenn Zotero eingerichtet ist..." -ForegroundColor DarkGray
    Read-Host | Out-Null
} else {
    Write-Host "In Zotero: Einstellungen -> Sync -> Datei-Sync -> WebDAV -> Server pruefen."
    Write-Host ""
    Write-Host "Dieses Fenster schliesst sich automatisch..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
}

exit 0
