#!/usr/bin/env powershell
param(
    [int]$Port = 8765,
    [switch]$OpenBrowser
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$UiDir = Join-Path $ScriptDir "ui"
Set-Location $ScriptDir

function Import-EnvFile {
    $values = [ordered]@{}
    if (-not (Test-Path ".env.local")) { return $values }
    Get-Content ".env.local" | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $key, $value = $line.Split("=", 2)
            $values[$key.Trim()] = $value.Trim()
        }
    }
    return $values
}

function Save-EnvFile {
    param([hashtable]$Values)
    $orderedKeys = @("GITHUB_USERNAME", "GITHUB_EMAIL", "GITHUB_TOKEN", "WEBDAV_URL", "WEBDAV_USERNAME", "WEBDAV_PASSWORD")
    $lines = @("# GitHub Configuration")
    foreach ($key in @("GITHUB_USERNAME", "GITHUB_EMAIL", "GITHUB_TOKEN")) {
        $lines += "$key=$($Values[$key])"
    }
    $lines += ""
    $lines += "# WebDAV Server"
    foreach ($key in @("WEBDAV_URL", "WEBDAV_USERNAME", "WEBDAV_PASSWORD")) {
        $lines += "$key=$($Values[$key])"
    }
    foreach ($key in $Values.Keys) {
        if ($orderedKeys -notcontains $key) {
            $lines += "$key=$($Values[$key])"
        }
    }
    $lines | Out-File ".env.local" -Encoding UTF8 -Force
}

function Get-RepoInfo {
    $remote = (git remote get-url origin 2>$null)
    if ($remote -match "github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(\.git)?/?$") {
        return @{ owner = $matches.owner; repo = $matches.repo; remote = $remote }
    }
    return @{ owner = ""; repo = ""; remote = $remote }
}

function Invoke-Git {
    param([string[]]$Args)
    $output = & git @Args 2>&1
    return @{ exitCode = $LASTEXITCODE; output = ($output -join "`n") }
}

function Invoke-GitRemote {
    param([string[]]$Args)
    $env = Import-EnvFile
    if ($env["GITHUB_TOKEN"]) {
        $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$($env["GITHUB_TOKEN"])"))
        $output = & git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basicAuth" @Args 2>&1
    }
    else {
        $output = & git @Args 2>&1
    }
    return @{ exitCode = $LASTEXITCODE; output = ($output -join "`n") }
}

function Get-AuthHeaders {
    $env = Import-EnvFile
    if (-not $env["GITHUB_TOKEN"]) { throw "GITHUB_TOKEN fehlt in .env.local" }
    return @{
        Authorization = "Bearer $($env["GITHUB_TOKEN"])"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "MyLiteratureVault"
    }
}

function Invoke-GitHub {
    param([string]$Method, [string]$Path, $Body = $null)
    $repo = Get-RepoInfo
    if (-not $repo.owner -or -not $repo.repo) { throw "GitHub Remote konnte nicht erkannt werden." }
    $uri = "https://api.github.com/repos/$($repo.owner)/$($repo.repo)$Path"
    $headers = Get-AuthHeaders
    if ($Body -ne $null) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body ($Body | ConvertTo-Json -Depth 10) -ContentType "application/json"
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Send-Response {
    param($Context, [int]$Status, [string]$Body, [string]$ContentType = "application/json")
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = "$ContentType; charset=utf-8"
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Send-Json {
    param($Context, $Object, [int]$Status = 200)
    Send-Response $Context $Status ($Object | ConvertTo-Json -Depth 20)
}

function Read-JsonBody {
    param($Request)
    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    return $raw | ConvertFrom-Json
}

function Pull-RemoteUpdates {
    $fetch = Invoke-GitRemote @("fetch", "--prune")
    $status = (git status --porcelain)
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        return @{ pulled = $false; skipped = $true; reason = "Lokale Aenderungen vorhanden"; fetch = $fetch.output }
    }
    $pull = Invoke-GitRemote @("pull", "--ff-only")
    return @{ pulled = ($pull.exitCode -eq 0); skipped = $false; output = $pull.output; exitCode = $pull.exitCode }
}

function Get-Status {
    $repo = Get-RepoInfo
    $branch = (git branch --show-current 2>$null)
    $short = (git status -sb 2>$null) -join "`n"
    $porcelain = (git status --porcelain 2>$null)
    $dataStatus = (git status --porcelain -- data 2>$null)
    $ignoredData = (git status --ignored --porcelain -- data 2>$null | Where-Object { $_.StartsWith("!!") })
    $ahead = 0
    $behind = 0
    $counts = (git rev-list --left-right --count HEAD...@{u} 2>$null)
    if ($LASTEXITCODE -eq 0 -and $counts) {
        $parts = "$counts".Trim() -split "\s+"
        $ahead = [int]$parts[0]
        $behind = [int]$parts[1]
    }
    return @{ repo = $repo; branch = $branch; short = $short; dirty = -not [string]::IsNullOrWhiteSpace($porcelain); dataChanges = @($dataStatus).Count; ignoredData = @($ignoredData).Count; ahead = $ahead; behind = $behind }
}

function Get-Log {
    $raw = git log --date=iso --max-count=80 --pretty=format:"%H%x1f%h%x1f%an%x1f%ae%x1f%ad%x1f%s" 2>$null
    $commits = @()
    foreach ($line in $raw) {
        $p = $line -split [char]31
        if ($p.Count -ge 6) {
            $commits += @{ hash = $p[0]; short = $p[1]; author = $p[2]; email = $p[3]; date = $p[4]; subject = $p[5] }
        }
    }
    return $commits
}

function Handle-Api {
    param($Context, [string]$Path)
    try {
        $method = $Context.Request.HttpMethod
        if ($Path -eq "/api/status") { Send-Json $Context (Get-Status); return }
        if ($Path -eq "/api/log") { Send-Json $Context (Get-Log); return }
        if ($Path -eq "/api/pull" -and $method -eq "POST") { Send-Json $Context (Pull-RemoteUpdates); return }
        if ($Path -eq "/api/settings" -and $method -eq "GET") {
            $env = Import-EnvFile
            Send-Json $Context @{
                githubUsername = $env["GITHUB_USERNAME"]
                githubEmail = $env["GITHUB_EMAIL"]
                tokenSet = -not [string]::IsNullOrWhiteSpace($env["GITHUB_TOKEN"])
                webdavUrl = $env["WEBDAV_URL"]
                webdavUsername = $env["WEBDAV_USERNAME"]
                webdavPassword = $env["WEBDAV_PASSWORD"]
            }
            return
        }
        if ($Path -eq "/api/settings" -and $method -eq "POST") {
            $body = Read-JsonBody $Context.Request
            $env = Import-EnvFile
            $env["GITHUB_USERNAME"] = "$($body.githubUsername)"
            $env["GITHUB_EMAIL"] = "$($body.githubEmail)"
            if (-not [string]::IsNullOrWhiteSpace("$($body.githubToken)")) { $env["GITHUB_TOKEN"] = "$($body.githubToken)" }
            $env["WEBDAV_URL"] = "$($body.webdavUrl)"
            $env["WEBDAV_USERNAME"] = "$($body.webdavUsername)"
            $env["WEBDAV_PASSWORD"] = "$($body.webdavPassword)"
            Save-EnvFile $env
            if ($env["GITHUB_USERNAME"]) { git config user.name "$($env["GITHUB_USERNAME"])" | Out-Null }
            if ($env["GITHUB_EMAIL"]) { git config user.email "$($env["GITHUB_EMAIL"])" | Out-Null }
            Send-Json $Context @{ ok = $true }
            return
        }
        if ($Path -eq "/api/issues") {
            $items = Invoke-GitHub "GET" "/issues?state=all&per_page=50"
            Send-Json $Context @($items | Where-Object { -not $_.pull_request })
            return
        }
        if ($Path -eq "/api/pulls") {
            Send-Json $Context (Invoke-GitHub "GET" "/pulls?state=all&per_page=50")
            return
        }
        if ($Path -match "^/api/issues/(\d+)$" -and $method -eq "PATCH") {
            Send-Json $Context (Invoke-GitHub "PATCH" "/issues/$($matches[1])" (Read-JsonBody $Context.Request))
            return
        }
        if ($Path -match "^/api/pulls/(\d+)$" -and $method -eq "PATCH") {
            Send-Json $Context (Invoke-GitHub "PATCH" "/pulls/$($matches[1])" (Read-JsonBody $Context.Request))
            return
        }
        Send-Json $Context @{ error = "Not found" } 404
    }
    catch {
        Send-Json $Context @{ error = "$($_.Exception.Message)" } 500
    }
}

function Serve-File {
    param($Context, [string]$Path)
    if ($Path -eq "/") { $Path = "/index.html" }
    $relative = $Path.TrimStart("/") -replace "/", [IO.Path]::DirectorySeparatorChar
    $file = Join-Path $UiDir $relative
    if (-not (Test-Path $file)) { Send-Response $Context 404 "Not found" "text/plain"; return }
    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
    $type = switch ($ext) { ".html" { "text/html" } ".css" { "text/css" } ".js" { "application/javascript" } default { "text/plain" } }
    Send-Response $Context 200 (Get-Content -Raw $file) $type
}

$listener = New-Object Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "MyLiteratureVault UI laeuft: $prefix" -ForegroundColor Green
if ($OpenBrowser) { Start-Process $prefix }

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $path = $context.Request.Url.AbsolutePath
        if ($path.StartsWith("/api/")) { Handle-Api $context $path } else { Serve-File $context $path }
    }
}
finally {
    $listener.Stop()
}
