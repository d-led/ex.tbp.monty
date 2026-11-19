<#
.SYNOPSIS
    Starts the two sample plugin nodes that ship with Monty Studio Desktop.

.DESCRIPTION
    ./start-plugins.ps1            ask the running window who it is, then join it
    ./start-plugins.ps1 node@host  join a node the window does not know about
    ./start-plugins.ps1 -Stop      end both

    The window is a named node (`monty-studio-<instance id>`), and the name is
    different every launch, so it cannot be written down here: it is asked for,
    over HTTP, at the address the window announces.

.PARAMETER Node
    The node to join, when the window cannot be asked.

.PARAMETER Stop
    End the plugin nodes.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Node,

    [switch] $Stop
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = if ($env:MONTY_DESKTOP_PORT) { $env:MONTY_DESKTOP_PORT } else { '42800' }
$examples = 'example_plugin', 'flyverse_plugin'

# The cluster's password. Every release carries a `releases\COOKIE` of its own -
# `mix release` writes one per build - so a plugin node started beside the window
# would be refused and would say so only as "no answer". The window's cookie is
# the one to share, and `rel\` is beside `plugins\` in every shape of the bundle.
# A deployment that set `MONTY_CLUSTER_SECRET` on the window sets it here too.
function Get-SharedCookie {
    if ($env:MONTY_CLUSTER_SECRET) { return $env:MONTY_CLUSTER_SECRET }
    if ($env:MONTY_COOKIE) { return $env:MONTY_COOKIE }

    $file = Join-Path (Split-Path -Parent $here) 'rel/ex_tbp_monty/releases/COOKIE'
    if (Test-Path $file) {
        return (Get-Content -Raw $file).Trim()
    }

    return $null
}

# A running node answers `rpc`, and nothing else in this folder does: that is the
# question, and it is also how one is stopped - a release started with `start` is
# not a daemon, so there is no pid file to trust.
function Test-Answering {
    param([string] $Example)

    $cookie = Get-SharedCookie
    if ($cookie) { $env:RELEASE_COOKIE = $cookie }

    # The node the release was started as: a long name on the loopback, so the
    # two find each other without asking DNS who this machine is.
    $env:RELEASE_DISTRIBUTION = 'name'
    $env:RELEASE_NODE = "$Example@127.0.0.1"

    $launcher = Join-Path $here "$Example/bin/$Example.bat"
    & $launcher rpc 'true' *> $null
    return $LASTEXITCODE -eq 0
}

if ($Stop) {
    foreach ($example in $examples) {
        if (Test-Answering $example) {
            $env:RELEASE_COOKIE = Get-SharedCookie
            & (Join-Path $here "$example/bin/$Example.bat") rpc 'System.stop()' *> $null
            Write-Host "  stopped $example"
        }
    }

    exit 0
}

foreach ($example in $examples) {
    if (Test-Answering $example) {
        Write-Host 'the sample plugin nodes are already running; -Stop ends them' -ForegroundColor Yellow
        exit 0
    }
}

$target = $Node

if (-not $target) {
    try {
        $answer = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 3
        $target = $answer.node
    } catch {
        $target = $null
    }

    if (-not $target) {
        Write-Host "no window answered on 127.0.0.1:$port with a node name." -ForegroundColor Yellow
        Write-Host '  Is Monty Studio running? Its window prints the port it chose.'
        Write-Host '  Was it started with MONTY_STUDIO_CLUSTER=0? Then it has no name to join.'
        exit 1
    }
}

Write-Host "joining $target"

$cookie = Get-SharedCookie

if (-not $cookie) {
    Write-Host 'no cookie to share with the window: is rel\ex_tbp_monty beside plugins\?' -ForegroundColor Yellow
    exit 1
}

foreach ($example in $examples) {
    $release = Join-Path $here $example
    $log = Join-Path $env:TEMP "monty-studio-$example.log"
    $launcher = Join-Path $release "bin/$example.bat"

    # The release names itself after itself (`sname`, `example_plugin@<host>`);
    # given a long name on the loopback instead, a short one is resolved through
    # DNS by the window that dials it back, and `MONTY_SEEDS` is the one line its
    # own `Join` module reads. The variables are the process's, so a 5.1
    # `Start-Process` inherits them without `-Environment`, which only 7 has.
    $env:RELEASE_COOKIE = $cookie
    $env:RELEASE_DISTRIBUTION = 'name'
    $env:RELEASE_NODE = "$example@127.0.0.1"
    $env:MONTY_SEEDS = $target

    Start-Process -FilePath $launcher -ArgumentList 'start' `
        -WorkingDirectory $release -WindowStyle Hidden `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" | Out-Null

    Write-Host "  $example`: log in $log"
}

Write-Host ''
Write-Host 'both are starting. Settings -> Cluster lists them once they are in.'
