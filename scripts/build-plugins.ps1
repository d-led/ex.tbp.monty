<#
.SYNOPSIS
    Builds the two sample plugin nodes into `_build/desktop/plugins\`.

.DESCRIPTION
    The counterpart of `scripts/build-plugins.sh`, for the platform whose release
    is a `.bat`. `bundle.resources` in `tauri.bundle.windows.json` copies the
    folder into the installer and beside the window, so it has to exist before
    `cargo tauri build` runs.

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
