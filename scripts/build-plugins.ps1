<#
.SYNOPSIS
    Builds the two sample plugin nodes into `_build/desktop/plugins\`.

.DESCRIPTION
    The counterpart of `scripts/build-plugins.sh`, for the platform whose release
    is a `.bat`. `scripts/package.sh` picks each release up from there to wrap in
    an application of its own, which is what the distribution ships: a plugin is a
    node, and it comes as a companion app beside the window rather than inside it.

    Releases and not escripts: `ex_tbp_monty_core` compiles native kernels, and an
    escript cannot load one.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$out = Join-Path $root '_build/desktop/plugins'

if (Test-Path $out) {
    Remove-Item -Recurse -Force $out
}
New-Item -ItemType Directory -Force -Path $out | Out-Null

foreach ($example in 'example_plugin', 'flyverse_plugin') {
    Write-Host "building examples/$example"
    $project = Join-Path $root "examples/$example"

    Push-Location $project
    try {
        $env:MIX_ENV = 'prod'
        mix deps.get | Out-Null
        mix release --overwrite | Out-Null
    } finally {
        Remove-Item Env:MIX_ENV -ErrorAction SilentlyContinue
        Pop-Location
    }

    Copy-Item -Recurse (Join-Path $project "_build/prod/rel/$example") (Join-Path $out $example)
}

Copy-Item (Join-Path $root 'scripts/desktop-plugins/start-plugins.sh') $out
Copy-Item (Join-Path $root 'scripts/desktop-plugins/start-plugins.ps1') $out
Copy-Item (Join-Path $root 'scripts/desktop-plugins/README.md') $out

Get-ChildItem $out | ForEach-Object {
    $size = if ($_.PSIsContainer) {
        '{0:N0} MB' -f ((Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
    } else { '' }
    Write-Host ("  {0} {1}" -f $_.Name, $size)
}
