#!/usr/bin/env powershell
param(
    [switch]$SkipDockerInstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

function Write-Step($Text) {
    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Ok($Text) {
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Info($Text) {
    Write-Host "[INFO] $Text" -ForegroundColor Gray
}

function Read-EnvFile {
    $values = @{}
    if (-not (Test-Path ".env.local")) {
        return $values
    }

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
    Write-Step "[1/5] Projekt einrichten"

    if (Test-Path ".env.local") {
        Write-Ok ".env.local ist vorhanden"
        return Read-EnvFile
    }

    Write-Host "Beim ersten Start brauche ich deine GitHub-Daten fuer automatische Commits und Pushes."
    $githubUser = Read-Host "GitHub Benutzername"
    $githubEmail = Read-Host "GitHub E-Mail"
    $githubToken = Read-Host "GitHub Personal Access Token (optional, Enter wenn Git bereits angemeldet ist)"

@"
# GitHub Configuration
GITHUB_USERNAME=$githubUser
GITHUB_EMAIL=$githubEmail
GITHUB_TOKEN=$githubToken

# WebDAV Server
WEBDAV_URL=http://localhost:8080
WEBDAV_USERNAME=zotero
WEBDAV_PASSWORD=changeme123
"@ | Out-File -FilePath ".env.local" -Encoding UTF8 -Force

    git config user.name "$githubUser"
    git config user.email "$githubEmail"
    Write-Ok ".env.local erstellt und Git-Benutzer gesetzt"
    return Read-EnvFile
}

function Ensure-DockerInstalled {
    Write-Step "[3/6] Docker pruefen"

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Ok "Docker ist installiert"
        return
    }

    if ($SkipDockerInstall) {
        throw "Docker ist nicht installiert. Starte ohne -SkipDockerInstall oder installiere Docker Desktop."
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Docker ist nicht installiert und winget wurde nicht gefunden. Bitte Docker Desktop installieren: https://www.docker.com/products/docker-desktop/"
    }

    Write-Host "Docker Desktop wird mit winget installiert. Das kann einige Minuten dauern."
    winget install --exact --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker wurde installiert, ist aber noch nicht im PATH. Bitte Windows einmal neu anmelden oder neu starten und quickstart.bat erneut ausfuehren."
    }
    Write-Ok "Docker installiert"
}

function Pull-RemoteUpdates {
    Write-Step "[2/6] GitHub-Stand pruefen"

    if ($env:GITHUB_TOKEN) {
        $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$($env:GITHUB_TOKEN)"))
        git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basicAuth" fetch --prune
    }
    else {
        git fetch --prune
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Fetch fehlgeschlagen. Quickstart arbeitet lokal weiter."
        return
    }

    $status = git status --porcelain
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        Write-Info "Pull uebersprungen, weil lokale Aenderungen vorhanden sind."
        return
    }

    if ($env:GITHUB_TOKEN) {
        $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$($env:GITHUB_TOKEN)"))
        git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basicAuth" pull --ff-only
    }
    else {
        git pull --ff-only
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Repository ist aktuell"
    }
    else {
        Write-Info "Pull nicht moeglich. Bitte Git-Status pruefen."
    }
}

function Start-DockerDesktop {
    Write-Step "[4/6] Docker starten"

    $dockerDesktop = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    if ($dockerDesktop) {
        Start-Process -FilePath $dockerDesktop -WindowStyle Hidden -ErrorAction SilentlyContinue
        Write-Info "Docker Desktop wurde gestartet oder lief bereits"
    }

    Write-Host "Warte auf Docker Engine..."
    $deadline = (Get-Date).AddMinutes(3)
    do {
        docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Docker Engine ist bereit"
            return
        }
        Start-Sleep -Seconds 3
        Write-Host -NoNewline "."
    } while ((Get-Date) -lt $deadline)

    throw "Docker Engine wurde nicht rechtzeitig bereit. Bitte Docker Desktop oeffnen und quickstart.bat erneut starten."
}

function Start-WebDav {
    Write-Step "[5/6] WebDAV Container starten"

    if (-not (Test-Path "data")) {
        New-Item -ItemType Directory -Path "data" | Out-Null
    }

    docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose ist nicht verfuegbar. Bitte Docker Desktop aktualisieren."
    }

    docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose konnte den WebDAV Container nicht starten."
    }

    Start-Sleep -Seconds 3
    docker ps --filter "name=zotero-webdav" --format "{{.Names}} {{.Status}}" | ForEach-Object { Write-Info $_ }
    Write-Ok "WebDAV laeuft auf http://localhost:8080"
}

function Start-AutoSync {
    Write-Step "[6/6] Auto-Sync starten"

    $syncScript = Join-Path $ScriptDir "auto-sync.ps1"
    if (-not (Test-Path $syncScript)) {
        throw "auto-sync.ps1 wurde nicht gefunden."
    }

    $existing = Get-CimInstance Win32_Process -Filter "name = 'powershell.exe' or name = 'pwsh.exe'" |
        Where-Object { $_.CommandLine -like "*auto-sync.ps1*" -and $_.CommandLine -like "*$ScriptDir*" }

    if ($existing) {
        Write-Ok "Auto-Sync laeuft bereits"
        return
    }

    Start-Process powershell -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$syncScript`"",
        "-WatchPath", "`"$ScriptDir\data`"",
        "-Push"
    ) -WindowStyle Normal

    Write-Ok "Auto-Sync wurde gestartet"
}

function Start-VaultUi {
    $uiScript = Join-Path $ScriptDir "vault-ui.ps1"
    if (-not (Test-Path $uiScript)) {
        Write-Info "UI wurde nicht gefunden."
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
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$uiScript`"",
        "-OpenBrowser"
    ) -WindowStyle Hidden
    Write-Ok "UI gestartet: http://localhost:8765"
}

Clear-Host
Write-Host "========================================" -ForegroundColor Blue
Write-Host "MyLiteratureVault Quickstart" -ForegroundColor Blue
Write-Host "========================================" -ForegroundColor Blue

$envValues = Ensure-EnvFile
Pull-RemoteUpdates
Ensure-DockerInstalled
Start-DockerDesktop
Start-WebDav
Start-AutoSync
Start-VaultUi

Write-Host ""
Write-Host "Fertig. Zotero kann jetzt WebDAV verwenden:" -ForegroundColor Green
Write-Host "  URL:      http://localhost:8080"
Write-Host "  Benutzer: zotero"
Write-Host "  Passwort: changeme123"
Write-Host ""
Write-Host "In Zotero: Einstellungen -> Sync -> Datei-Sync -> WebDAV -> Server pruefen."
Write-Host "Alle Aenderungen unter ./data werden automatisch committed und gepusht."
Write-Host "UI: http://localhost:8765"
