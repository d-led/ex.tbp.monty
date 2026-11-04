<#
.SYNOPSIS
    Installs the desktop window on Windows: one folder, nothing to install, no
    administrator.

.DESCRIPTION
    The Windows form of `scripts/install-desktop.sh`, and what
    `scripts\package.ps1` names as the thing that downloads its zip:

        powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/scripts/install-desktop.ps1 | iex"

    What it installs is the newest build of `main` — there is no release to wait
    for. A tagged release keeps the same file in the releases page, which is what
    to use for a version that has to stay put.

        EX_TBP_MONTY_APP_DIR   where to put it (default: %LOCALAPPDATA%\Programs)
        EX_TBP_MONTY_REPO      owner/repo to download from (default: d-led/ex.tbp.monty)
        EX_TBP_MONTY_BRANCH    which branch's build to take (default: main)
        EX_TBP_MONTY_WORKFLOW  the workflow that builds it (default: ci)
        EX_TBP_MONTY_BASE_URL  a folder holding ex-tbp-monty-win-x64.zip itself,
                               which skips nightly.link

    Nothing is written outside the target folder, and nothing is registered: the
    folder runs from anywhere, which is the same offer `package.ps1` makes with
    its portable folder. The NSIS setup is for a person who wants a Start Menu
    entry and an entry under "Apps & features"; this script does not need one.

.NOTES
    The build it downloads is compiled in CI but has never been started on
    Windows — `docs/desktop.md` says what is verified and what is claimed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'The desktop window is built for Windows here, and this is not Windows: there is nothing to install.'
    Write-Host 'What exists, and what is missing, is in docs/desktop.md. A checkout can build its own copy:'
    Write-Host '  scripts\start-desktop.ps1'
    exit 1
}

$repo = if ($env:EX_TBP_MONTY_REPO) { $env:EX_TBP_MONTY_REPO } else { 'd-led/ex.tbp.monty' }
$branch = if ($env:EX_TBP_MONTY_BRANCH) { $env:EX_TBP_MONTY_BRANCH } else { 'main' }
$workflow = if ($env:EX_TBP_MONTY_WORKFLOW) { $env:EX_TBP_MONTY_WORKFLOW } else { 'ci' }
$appDir = if ($env:EX_TBP_MONTY_APP_DIR) { $env:EX_TBP_MONTY_APP_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs' }
$asset = 'ex-tbp-monty-win-x64'

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ex-tbp-monty-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $zip = Join-Path $work "$asset.zip"

    if ($env:EX_TBP_MONTY_BASE_URL) {
        # A folder on this machine is how the packaging is tried without a
        # network round trip, which is what the shell twin does too.
        $source = Join-Path $env:EX_TBP_MONTY_BASE_URL "$asset.zip"
        Write-Host "Downloading $asset from $env:EX_TBP_MONTY_BASE_URL ..."
        if (Test-Path $source) { Copy-Item $source $zip } else { Invoke-WebRequest -Uri $source -OutFile $zip }
    }
    else {
        $url = "https://nightly.link/$repo/workflows/$workflow/$branch/$asset.zip"
        Write-Host "Downloading the newest $branch build: $url"
        Invoke-WebRequest -Uri $url -OutFile $zip
    }

    # Two layers, because two tools zip: nightly.link wraps the artefact in a zip
    # of its own (`BASE_URL` skips that wrapper), and the artefact is the folder
    # zipped — a release is tens of thousands of files, and `Compress-Archive`
    # would hold half a gigabyte of file table in memory doing it. `tar` reads
    # both: Windows ships bsdtar, which understands zip.
    #
    # Said out loud, because both steps take a while and a script that prints
    # nothing for a minute reads as one that has hung.
    Write-Host 'Unpacking the download ...'
    $unpacked = Join-Path $work 'unpacked'
    New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
    tar -x -f $zip -C $unpacked
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'The download could not be unpacked. Nothing was installed.'
        exit 1
    }

    $bundle = Get-ChildItem -Path $unpacked -Filter '*.zip' -File | Select-Object -First 1
    if ($null -ne $bundle) {
        Write-Host 'Expanding the application (about 550 MB) ...'
        $unpacked = Join-Path $work 'app'
        New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
        tar -x -f $bundle.FullName -C $unpacked
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'The application could not be expanded. Nothing was installed.'
            exit 1
        }
    }

    # Found rather than assumed: the folder's name is the runtime the build was
    # for, and what makes it the application is the window inside it.
    $exe = Get-ChildItem -Path $unpacked -Recurse -Filter 'ex-tbp-monty-desktop.exe' -File |
        Select-Object -First 1
    if ($null -eq $exe) {
        Write-Host 'The download did not contain the application. Nothing was installed.'
        exit 1
    }

    $name = $exe.Directory.Name
    $target = Join-Path $appDir $name
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    Remove-Item -Recurse -Force $target -ErrorAction SilentlyContinue
    Move-Item -Path $exe.Directory.FullName -Destination $target

    $installed = Join-Path $target $exe.Name

    # A file that arrived through `Invoke-WebRequest` can carry a zone identifier,
    # and Windows then asks before running it. Ask once and only when one is
    # there: walking fifteen thousand files to delete a marker none of them has
    # is a minute spent on nothing.
    if ($null -ne (Get-Item $installed -Stream Zone.Identifier -ErrorAction SilentlyContinue)) {
        Write-Host 'Clearing the download marker ...'
        Get-ChildItem -Path $target -Recurse -File | Unblock-File
    }

    Write-Host ''
    Write-Host "Installed $installed"
    Write-Host "Open it with:  $installed"
    Write-Host "Where it keeps its data:  $env:APPDATA\ex-tbp-monty"
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
