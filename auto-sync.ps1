#!/usr/bin/env powershell
param(
    [string]$WatchPath = ".\data",
    [int]$IntervalSeconds = 5,
    [int]$DebounceSeconds = 10,
    [switch]$Push
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

function Write-Log($Text, $Color = "Gray") {
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Text" -ForegroundColor $Color
}

function Import-LocalEnv {
    if (-not (Test-Path ".env.local")) {
        return
    }

    Get-Content ".env.local" | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $key, $value = $line.Split("=", 2)
            [Environment]::SetEnvironmentVariable($key.Trim(), $value.Trim(), "Process")
        }
    }
}

function Ensure-GitIdentity {
    $name = git config user.name
    $email = git config user.email

    if ([string]::IsNullOrWhiteSpace($name) -and $env:GITHUB_USERNAME) {
        git config user.name "$env:GITHUB_USERNAME" | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($email) -and $env:GITHUB_EMAIL) {
        git config user.email "$env:GITHUB_EMAIL" | Out-Null
    }
}

function Push-CurrentBranch {
    if (-not $Push) {
        return
    }

    if ($env:GITHUB_TOKEN) {
        $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$($env:GITHUB_TOKEN)"))
        git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basicAuth" push
    }
    else {
        git push
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Push zu GitHub erfolgreich." "Green"
        return
    }

    Write-Log "Normaler Push fehlgeschlagen, versuche Upstream fuer aktuellen Branch zu setzen..." "Yellow"
    if ($env:GITHUB_TOKEN) {
        $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$($env:GITHUB_TOKEN)"))
        git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basicAuth" push -u origin HEAD
    }
    else {
        git push -u origin HEAD
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Log "Push zu GitHub erfolgreich." "Green"
    }
    else {
        Write-Log "Push fehlgeschlagen. GitHub-Anmeldung oder Remote pruefen." "Red"
    }
}

function Invoke-GitRemote {
    param([string[]]$Args)
    if ($env:GITHUB_TOKEN) {
        $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$($env:GITHUB_TOKEN)"))
        & git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basicAuth" @Args
    }
    else {
        & git @Args
    }
}

function Test-BranchHasUnpushedCommits {
    $branchStatus = git status -sb
    return ($branchStatus -match "\[ahead [0-9]+")
}

function Pull-RemoteUpdates {
    Write-Log "Pruefe GitHub auf neuere Commits..." "Cyan"
    Invoke-GitRemote @("fetch", "--prune")
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Fetch fehlgeschlagen. Arbeite lokal weiter." "Yellow"
        return
    }

    $status = git status --porcelain
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        Write-Log "Pull uebersprungen, weil lokale Aenderungen vorhanden sind." "Yellow"
        return
    }

    Invoke-GitRemote @("pull", "--ff-only")
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Remote-Stand ist aktuell oder wurde gepulled." "Green"
    }
    else {
        Write-Log "Pull fehlgeschlagen. Bitte Git-Status pruefen." "Red"
    }
}

function Get-RelativeWatchPath {
    param([string]$FullPath)

    $root = (Resolve-Path $ScriptDir).Path.TrimEnd("\", "/")
    $resolved = (Resolve-Path $FullPath).Path.TrimEnd("\", "/")
    if ($resolved.StartsWith($root)) {
        return $resolved.Substring($root.Length).TrimStart("\", "/")
    }
    return $FullPath
}

function Sync-Changes {
    param([string]$RelativePath)

    $status = git status --porcelain -- "$RelativePath"
    if ([string]::IsNullOrWhiteSpace($status)) {
        return
    }

    Write-Log "Aenderungen gefunden. Commit wird vorbereitet..." "Yellow"
    git add -A -- "$RelativePath"

    $staged = git diff --cached --quiet -- "$RelativePath"
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Keine commitbaren Aenderungen nach git add." "Gray"
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    git commit -m "Auto-sync Zotero WebDAV data [$timestamp]"
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Commit fehlgeschlagen. Bitte Git-Konfiguration pruefen." "Red"
        return
    }

    Write-Log "Commit erstellt." "Green"

    Push-CurrentBranch
}

Import-LocalEnv
Ensure-GitIdentity
Pull-RemoteUpdates

$watchFullPath = if ([System.IO.Path]::IsPathRooted($WatchPath)) { $WatchPath } else { Join-Path $ScriptDir $WatchPath }
if (-not (Test-Path $watchFullPath)) {
    New-Item -ItemType Directory -Path $watchFullPath -Force | Out-Null
}

$relativeWatchPath = Get-RelativeWatchPath $watchFullPath

Write-Log "Auto-Sync startet." "Green"
Write-Log "Ueberwache: $relativeWatchPath" "Cyan"
Write-Log "Intervall: ${IntervalSeconds}s, Ruhezeit vor Commit: ${DebounceSeconds}s" "Cyan"
Write-Log "Push nach GitHub: $([bool]$Push)" "Cyan"
Write-Log "Beenden mit Ctrl+C." "Gray"

$lastStatus = ""
$lastChangeAt = Get-Date
$lastPushAttempt = (Get-Date).AddMinutes(-5)

try {
    while ($true) {
        $currentStatus = (git status --porcelain -- "$relativeWatchPath") -join "`n"

        if ($currentStatus -ne $lastStatus) {
            $lastStatus = $currentStatus
            $lastChangeAt = Get-Date
            if (-not [string]::IsNullOrWhiteSpace($currentStatus)) {
                Write-Log "Zotero-Daten wurden geaendert. Warte auf weitere Schreibvorgaenge..." "Cyan"
            }
        }

        $idleSeconds = ((Get-Date) - $lastChangeAt).TotalSeconds
        if (-not [string]::IsNullOrWhiteSpace($currentStatus) -and $idleSeconds -ge $DebounceSeconds) {
            Sync-Changes -RelativePath $relativeWatchPath
            $lastStatus = (git status --porcelain -- "$relativeWatchPath") -join "`n"
            $lastChangeAt = Get-Date
        }
        elseif ([string]::IsNullOrWhiteSpace($currentStatus) -and $Push -and ((Get-Date) - $lastPushAttempt).TotalSeconds -ge 60 -and (Test-BranchHasUnpushedCommits)) {
            Write-Log "Lokale Commits sind noch nicht auf GitHub. Push wird erneut versucht..." "Yellow"
            $lastPushAttempt = Get-Date
            Push-CurrentBranch
            $lastChangeAt = Get-Date
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    Write-Log "Auto-Sync beendet." "Yellow"
}
