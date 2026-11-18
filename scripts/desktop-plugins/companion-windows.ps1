# The launcher inside a companion plugin folder on Windows: start this node,
# joined to the window beside it.
#
#   Double-click `ex.tbp.monty.plugin.example.cmd`, which runs this file.
#
# The macOS launcher is `companion-app.sh` and the Linux one is
# `companion-linux.sh`; this is the third shape of the same three facts. Windows
# has no bundle either, so the folder holds the launcher, one line naming the
# release, and the release itself:
#
#   ex.tbp.monty.plugin.example\
#     ex.tbp.monty.plugin.example.cmd   the click
#     companion-windows.ps1             this file, which the .cmd runs
#     node                              one line: example_plugin
#     example_plugin\                   the release, with its own runtime
#
# and the window is `ex-tbp-monty-desktop.exe` in the folder above, beside that
# folder rather than inside it, the same arrangement as Linux, so one sentence
# describes both.
#
# The two things a launcher cannot guess are the ones the macOS one cannot either:
# the node name (`/health` answers with it, because the window names itself per
# launch) and the cookie (`releases\COOKIE` of the window's own release, because
# `mix release` writes one per build and a peer with a different one is refused,
# which arrives as "nothing happened").
#
# Written for Windows PowerShell 5.1, which is what a person has: no `??`, no
# ternary, no `Get-Content -AsByteStream`.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$name = Split-Path -Leaf $here
$folder = Split-Path -Parent $here

function Say([string]$message) {
    # Appended, never truncated: a second click must not delete the log the node
    # already running is writing.
    $log = Join-Path ([System.IO.Path]::GetTempPath()) 'monty-studio-companion.log'
    Add-Content -Path $log -Value $message -ErrorAction SilentlyContinue
    Write-Host $message
}

function Die([string]$message) {
    Say $message
    # A click has no terminal, so the sentence has to survive it.
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    if ([System.Windows.Forms.SystemInformation]::UserInteractive) {
        [System.Windows.Forms.MessageBox]::Show($message, $name, 'OK', 'Warning') | Out-Null
    }
    exit 1
}

$nodeFile = Join-Path $here 'node'

if (-not (Test-Path $nodeFile)) {
    Die "$name is not a plugin folder: node is missing beside the launcher."
}

$node = (Get-Content $nodeFile -Raw).Trim()

$window = $env:MONTY_STUDIO_APP

if ([string]::IsNullOrEmpty($window)) {
    $window = Join-Path $folder 'ex-tbp-monty-desktop.exe'
}

if (-not (Test-Path $window)) {
    Die "There is no Monty Studio window beside $name. Put the two in the same folder, or set MONTY_STUDIO_APP to the window's .exe."
}

$windowDir = Split-Path -Parent $window
$releaseDir = Join-Path $windowDir 'rel\ex_tbp_monty'

$release = Join-Path $here $node

if (-not (Test-Path (Join-Path $release "bin\$node.bat"))) {
    Die "This folder carries no $node release. It was packaged without one: rebuild it with scripts\package.ps1."
}

function WindowPort {
    if (-not [string]::IsNullOrEmpty($env:MONTY_DESKTOP_PORT)) {
        return $env:MONTY_DESKTOP_PORT
    }

    $settings = Join-Path $env:APPDATA 'ex-tbp-monty\desktop_port'

    if (Test-Path $settings) {
        $port = (Get-Content $settings -Raw).Trim()

        if ($port -match '^[0-9]+$') {
            return $port
        }
    }

    return '42800'
}

function Answered([string]$port) {
    try {
        return (Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$port/health").Content
    } catch {
        # A window that answers 503 still names the node it is, so the body of a
        # failed request is an answer rather than nothing.
        if ($null -ne $_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }

        return ''
    }
}

$port = WindowPort
$said = Answered $port

if ([string]::IsNullOrEmpty($said)) {
    Say "opening $window, then waiting for it to answer on port $port"
    Start-Process -FilePath $window

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Seconds 1
        $said = Answered $port

        if (-not [string]::IsNullOrEmpty($said)) {
            break
        }
    }
}

if ([string]::IsNullOrEmpty($said)) {
    Die "Nothing answered on 127.0.0.1:$port, so there is no window to join."
}

$match = [regex]::Match($said, '"node":"([^"]*)"')

if (-not $match.Success -or $match.Groups[1].Value -eq '') {
    Die "The window on port $port answered without a node name: it was started with MONTY_STUDIO_CLUSTER=0, so it has nobody to join."
}

$target = $match.Groups[1].Value
$cookie = $env:MONTY_CLUSTER_SECRET

if ([string]::IsNullOrEmpty($cookie)) {
    $cookie = $env:MONTY_COOKIE
}

if ([string]::IsNullOrEmpty($cookie)) {
    $cookieFile = Join-Path $releaseDir 'releases\COOKIE'

    if (-not (Test-Path $cookieFile)) {
        Die "There is no cookie to join the window with: $cookieFile is not readable. A window started with MONTY_CLUSTER_SECRET has to give the companion the same variable."
    }

    $cookie = (Get-Content $cookieFile -Raw).Trim()
}

# Pressing it twice is not an error: a running node answers, and answers is the
# whole question. A release started with `start` is not a daemon.
$env:RELEASE_COOKIE = $cookie
$already = & (Join-Path $release "bin\$node.bat") rpc "true" 2>&1

if ($LASTEXITCODE -eq 0) {
    Say "$name is already running, and is in the cluster."
    exit 0
}

Say "${name}: joining $target (the window answers on port $port)"

# A launcher defaults each `RELEASE_*` only while it is unset, so one inherited
# from a release's own shell sends this node looking for a release folder of that
# name and version, where it dies on its first line.
Remove-Item Env:\RELEASE_VSN -ErrorAction SilentlyContinue
Remove-Item Env:\RELEASE_NAME -ErrorAction SilentlyContinue
Remove-Item Env:\RELEASE_ROOT -ErrorAction SilentlyContinue
Remove-Item Env:\RELEASE_NODE -ErrorAction SilentlyContinue
Remove-Item Env:\RELEASE_DISTRIBUTION -ErrorAction SilentlyContinue
Remove-Item Env:\RELEASE_TMP -ErrorAction SilentlyContinue
Remove-Item Env:\RELEASE_MODE -ErrorAction SilentlyContinue

$env:MONTY_SEEDS = $target
Set-Location $release
& (Join-Path $release "bin\$node.bat") start
exit $LASTEXITCODE
