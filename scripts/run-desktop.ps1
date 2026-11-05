<#
.SYNOPSIS
    Runs the desktop window on Windows: one folder, nothing installed, no
    administrator.

.DESCRIPTION
    The Windows form of `scripts/run-desktop.sh`, and what `scripts\package.ps1`
    names as the thing that downloads its zip:

        powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/scripts/run-desktop.ps1 | iex"

    The download lands in the folder this is run from, in a directory of its
    own — nothing is copied anywhere, nothing is registered, and deleting the
    folder is the whole of removing it. Run it again and it opens what is already
    there; -Update takes the newest build of `main` first. A tagged release keeps
    the same file in the releases page, which is what to use for a version that
    has to stay put.

        -Update                download the newest build even if one is here

        EX_TBP_MONTY_NO_LAUNCH stop after unpacking, print where the window is
                               (what CI runs to test this script)
        EX_TBP_MONTY_DIR       where it lands (default: .\ex-tbp-monty-win-x64)
        EX_TBP_MONTY_REPO      owner/repo to download from (default: d-led/ex.tbp.monty)
        EX_TBP_MONTY_BRANCH    which branch's build to take (default: main)
        EX_TBP_MONTY_WORKFLOW  the workflow that builds it (default: ci)
        EX_TBP_MONTY_BASE_URL  a folder holding ex-tbp-monty-win-x64.zip itself,
                               which skips nightly.link

    The NSIS setup in the same download is for a person who wants a Start Menu
    entry and an entry under "Apps & features"; this script does not need one.

.NOTES
    The build it downloads is compiled in CI but has never been started on
    Windows — `docs/desktop.md` says what is verified and what is claimed.
#>

param(
    [switch]$Update
)

# `irm … | iex` cannot pass a switch: the one-liner's form of -Update is the
# environment, `$env:EX_TBP_MONTY_UPDATE = 1`.
if ($env:EX_TBP_MONTY_UPDATE -in @('1', 'true', 'yes')) { $Update = $true }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'The desktop window runs on Windows here, and this is not Windows: there is nothing to run.'
    Write-Host 'What exists, and what is missing, is in docs/desktop.md. A checkout can build its own copy:'
    Write-Host '  scripts\start-desktop.ps1'
    exit 1
}

$repo = if ($env:EX_TBP_MONTY_REPO) { $env:EX_TBP_MONTY_REPO } else { 'd-led/ex.tbp.monty' }
$branch = if ($env:EX_TBP_MONTY_BRANCH) { $env:EX_TBP_MONTY_BRANCH } else { 'main' }
$workflow = if ($env:EX_TBP_MONTY_WORKFLOW) { $env:EX_TBP_MONTY_WORKFLOW } else { 'ci' }
$asset = 'ex-tbp-monty-win-x64'
$dir = if ($env:EX_TBP_MONTY_DIR) { $env:EX_TBP_MONTY_DIR } else { Join-Path $PWD $asset }
$instance = Join-Path $dir $asset
$exe = Join-Path $instance 'ex-tbp-monty-desktop.exe'

if (-not $Update -and (Test-Path $exe)) {
    Write-Host "$exe is already here."
}
else {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $dir "$asset.zip"
    $work = Join-Path $dir '.unpacked'

    $folder = $env:EX_TBP_MONTY_BASE_URL
    if ($folder) {
        # A folder on this machine is how the packaging is tried without a
        # network round trip, which is what the shell twin does too.
        $source = Join-Path $folder "$asset.zip"
        Write-Host "Taking $source ..."
        Copy-Item -LiteralPath $source -Destination $zip
    }
    else {
        $source = "https://nightly.link/$repo/workflows/$workflow/$branch/$asset.zip"
        Write-Host "Downloading the newest $branch build: $source"
        # The progress bar is why a 230 MB download takes minutes in Windows
        # PowerShell: it redraws the console for every block it receives.
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $source -OutFile $zip
        }
        catch {
            # Said as a sentence instead of thrown, because an artefact that is
            # not there yet is the expected answer while a platform's build is
            # red.
            Write-Host "Nothing came from $source — $($_.Exception.Message)"
            Write-Host 'Nothing was run. Whether that build exists is on the workflow page:'
            Write-Host "  https://github.com/$repo/actions/workflows/$workflow.yml"
            exit 1
        }
    }

    # Two layers, because two tools zip: nightly.link wraps the artefact in a zip
    # of its own (`BASE_URL` skips that wrapper), and the artefact is the folder
    # zipped — a release is tens of thousands of files, and `Compress-Archive`
    # would hold half a gigabyte of file table in memory doing it. `tar` reads
    # both: Windows ships bsdtar, which understands zip.
    #
    # Neither layer's exit code is the gate. A zip of sixteen thousand files can
    # carry an entry this tar cannot read — ERTS ships `.pdb` debug symbols, and
    # one of them fails to extract — while handing over everything the
    # application needs; the packaging excludes them now, and this still does not
    # trust the code, because the question is "is the application here", and that
    # is answered by looking. The unpacker's own words are kept for the case
    # where the answer is no.
    #
    # Said out loud, because both steps take a while and a script that prints
    # nothing for a minute reads as one that has hung.
    Write-Host 'Unpacking the download ...'
    $log = Join-Path $work 'unpack.log'
    $unpacked = Join-Path $work 'unpacked'
    New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
    tar -x -f $zip -C $unpacked 2>$log

    # The inner zip is looked for two levels down, not only at the top: a wrapper
    # directory around it is a packaging detail, and the search should not care.
    $bundle = Get-ChildItem -Path $unpacked -Recurse -Depth 1 -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $bundle) {
        Write-Host 'Expanding the application (about 550 MB) ...'
        $unpacked = Join-Path $work 'app'
        New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
        tar -x -f $bundle.FullName -C $unpacked 2>>$log
    }

    # Found rather than assumed: the folder's name is the runtime the build was
    # for, and what makes it the application is the window inside it.
    $found = Get-ChildItem -Path $unpacked -Recurse -Filter 'ex-tbp-monty-desktop.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $found) {
        Write-Host 'The download did not contain the application. Nothing was run.'
        Write-Host 'What it does hold:'
        Get-ChildItem -Path $unpacked -ErrorAction SilentlyContinue |
            Select-Object -First 10 |
            ForEach-Object { Write-Host "  $($_.Name)" }
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 0) {
            Write-Host 'The unpacker said:'
            Get-Content $log -ErrorAction SilentlyContinue |
                Select-Object -Last 10 |
                ForEach-Object { Write-Host "  $_" }
        }
        Write-Host 'The NSIS setup in the same download installs the same application,'
        Write-Host 'and does not go through this script:'
        Write-Host '  docs/desktop.md'
        exit 1
    }

    Remove-Item -Recurse -Force $instance -ErrorAction SilentlyContinue
    Move-Item -Path $found.Directory.FullName -Destination $instance

    # A file that arrived through `Invoke-WebRequest` can carry a zone identifier,
    # and Windows then asks before running it. Ask once and only when one is
    # there: walking fifteen thousand files to delete a marker none of them has
    # is a minute spent on nothing.
    #
    # `-Stream` belongs to Windows' filesystem provider alone, so it is only asked
    # for where it exists — and a backslash separator is how this script tells,
    # because `$IsWindows` does not exist in Windows PowerShell 5.1. (Which also
    # makes the whole unpack path testable on a machine that is not Windows.)
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\' -and
        $null -ne (Get-Item $exe -Stream Zone.Identifier -ErrorAction SilentlyContinue)) {
        Write-Host 'Clearing the download marker ...'
        Get-ChildItem -Path $instance -Recurse -File | Unblock-File
    }

    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($env:EX_TBP_MONTY_NO_LAUNCH -in @('1', 'true', 'yes')) {
    Write-Host "Not launching: $exe"
    exit 0
}

Write-Host "Running $exe"
Start-Process -FilePath $exe -WorkingDirectory $instance
Write-Host "Where it keeps its data:  $env:APPDATA\ex-tbp-monty"
