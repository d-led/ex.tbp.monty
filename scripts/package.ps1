<#
.SYNOPSIS
    Builds what a person can install on Windows.

.DESCRIPTION
    The Windows form of `scripts/package.sh`. Two things come out of it, and they
    are not the same offer:

        folder     `artifacts\win-x64\ex-tbp-monty-win-x64\` - the window with the
                   release beside it. Runs from anywhere, no installer, no
                   administrator. This is what CI uploads as
                   `ex-tbp-monty-win-x64.zip`, so it is also what
                   `scripts\run-desktop.ps1` would download.
        .zip       that folder, zipped (`-NoZip` skips it)
        setup      the NSIS installer Tauri makes (`-NoInstaller` skips it):
                   double-click, app appears under %LOCALAPPDATA%\Programs

    All of them carry the same bundle - the window, the Elixir release, the BEAM,
    the embedded Python - so the only difference is how a person picks it up.

        scripts\package.ps1                  # the platform this machine is
        scripts\package.ps1 win-x64          # one named runtime
        scripts\package.ps1 all              # everything this machine can build
        scripts\package.ps1 -NoZip           # skip the zip (the folder is still made)
        scripts\package.ps1 -NoInstaller     # skip the installer

    A platform is built on a machine of that platform: the release carries a
    compiled Python, two Rust NIFs and a webview shell, none of which
    cross-compile cheaply. `all` therefore means "the host", and a platform that
    is named but not this machine's is refused rather than faked.

    Everything lands in `artifacts\`, which is not committed.

.NOTES
    Not yet built or run on a Windows machine - `docs/desktop.md` says what is
    verified and what is claimed.
#>

param(
    [Parameter(Position = 0)]
    [string[]]$Runtime,

    [switch]$NoZip,
    [switch]$NoInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Push-Location (Split-Path -Parent $PSScriptRoot)

try {
    $artifacts = 'artifacts'
    $product = 'Monty on the BEAM'

    function Get-HostRid {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { return 'win-arm64' }
        return 'win-x64'
    }

    if ($null -eq $Runtime -or $Runtime.Count -eq 0) {
        $Runtime = @(Get-HostRid)
    }

    $rids = @()
    foreach ($argument in $Runtime) {
        switch ($argument) {
            'all' { $rids += Get-HostRid }
            'win-x64' { $rids += $argument }
            'win-arm64' { $rids += $argument }
            default {
                Write-Host "usage: scripts\package.ps1 [all|win-x64|win-arm64] [-NoZip] [-NoInstaller]"
                exit 64
            }
        }
    }

    $version = (Select-String -Path mix.exs -Pattern '^\s*@version "(.*)"$').Matches[0].Groups[1].Value
    if (-not $version) { $version = '0.1.0' }

    Write-Host "$product $version`: $($rids -join ' ')"

    New-Item -ItemType Directory -Force -Path $artifacts | Out-Null

    # One bundle: the stylesheet, the scripts, `mix release`, and the window with
    # that release copied beside it. `start-desktop.ps1` owns those steps - this
    # script must not have a second version of them.
    function Build-App {
        & (Join-Path $PSScriptRoot 'start-desktop.ps1') -Bundle
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'the build failed; nothing was packaged'
            exit 1
        }

        if (-not (Test-Path 'src-tauri/target/release/ex-tbp-monty-desktop.exe')) {
            Write-Host 'the build said it finished and there is no window binary'
            exit 1
        }
    }

    # What the window reads at run time: `rel\` beside it is `bundle.resources`
    # resolved, so the folder is a self-contained copy of the application.
    function New-PortableFolder {
        param([string]$Rid)

        $target = Join-Path $artifacts "$Rid/ex-tbp-monty-$Rid"
        Remove-Item -Recurse -Force $target -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $target | Out-Null

        Copy-Item 'src-tauri/target/release/ex-tbp-monty-desktop.exe' $target
        Copy-Item -Recurse 'src-tauri/target/release/rel' $target

        Write-Host "  $target"
        return $target
    }

    function New-ZipArchive {
        param([string]$Rid, [string]$Source)

        $target = Join-Path $PWD "$artifacts/$Rid/ex-tbp-monty-$Rid.zip"
        Remove-Item -Force $target -ErrorAction SilentlyContinue

        # `tar`, not `Compress-Archive`: Windows ships bsdtar, it keeps the
        # directory entries a release expects, and it does not try to hold half a
        # gigabyte of file table in memory. The extension is what asks for zip.
        #
        # `.pdb` and not shipped: ERTS carries nineteen of them, ~90 MB of this
        # download, and they are debug symbols for a binary nobody debugs here.
        # One of them (`beam.debug.smp.pdb`) also fails to extract with the
        # bsdtar that ships on Windows and macOS, which made the download look
        # broken to `run-desktop.ps1` while everything it needed had unpacked.
        Push-Location (Split-Path -Parent $Source)
        try {
            tar -a -c -f $target --exclude '*.pdb' (Split-Path -Leaf $Source)
        }
        finally {
            Pop-Location
        }

        Write-Host "  $target"
    }

    function Copy-Installer {
        param([string]$Rid)

        $setup = Get-ChildItem -Path 'src-tauri/target/release/bundle/nsis' -Filter '*-setup.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -eq $setup) {
            Write-Host '  no NSIS bundle: no installer for this run' -ForegroundColor Yellow
            return
        }

        $target = Join-Path $PWD "$artifacts/$Rid/monty-on-the-beam-$version-setup.exe"
        Copy-Item $setup.FullName $target -Force
        Write-Host "  $target"
    }

    foreach ($rid in $rids) {
        if ($rid -ne (Get-HostRid)) {
            Write-Host "scripts\package.ps1 builds $rid only on a $rid machine; this one is $(Get-HostRid)."
            Write-Host 'What a platform still needs is in docs/desktop.md.'
            exit 1
        }

        Write-Host $rid

        Remove-Item -Recurse -Force (Join-Path $artifacts $rid) -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path (Join-Path $artifacts $rid) | Out-Null

        Build-App
        $folder = New-PortableFolder -Rid $rid

        if (-not $NoZip) {
            New-ZipArchive -Rid $rid -Source $folder
        }

        if (-not $NoInstaller) {
            Copy-Installer -Rid $rid
        }
    }

    $count = (Get-ChildItem -Path (Join-Path $artifacts '*/*') -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host "done: $count artifacts in $artifacts\<platform>\"
}
finally {
    Pop-Location
}
