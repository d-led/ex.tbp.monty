<#
.SYNOPSIS
    Opens the desktop window on Windows.

.DESCRIPTION
    The Windows form of `scripts/start-desktop.sh`: the same steps, in the same
    order, with the same names, so a change made to one is a change to the
    other.

        scripts\start-desktop.ps1                build both halves, then open the window
        scripts\start-desktop.ps1 -InBrowser     build the release, then serve it here
        scripts\start-desktop.ps1 -Where         build the release, then print where its data is
        scripts\start-desktop.ps1 -Bundle        build the app bundle, then print its path
        scripts\start-desktop.ps1 -App           build the app bundle, then open the app

    What it opens is the native window: `src-tauri`, which starts the Elixir
    release as its sidecar, reads the address that release prints, and points a
    webview at it. The window adds no behaviour — every screen is the sidecar's,
    which is also what `-InBrowser` runs, so the desktop and the server cannot
    drift apart.

    Nothing here is backgrounded or piped: every command writes to this
    terminal as it runs, and the first one that fails stops the script.

    What a machine needs first: Elixir and Mix, the Rust toolchain (rustup),
    Node.js, the MSVC build tools and WebView2. The first three are named if
    they are absent; Hex, rebar, the npm packages, the Tauri CLI and the
    dependencies install themselves.

.NOTES
    Not yet built or run on a Windows machine — `docs/desktop.md` says what is
    verified and what is claimed. The parts most likely to need work are the
    NSIS bundle and MuJoCo's renderer, which defaults to WGL here and has no
    `MUJOCO_GL` equivalent in `rel/env.bat.eex`.
#>

param(
    [switch]$InBrowser,
    [switch]$Where,
    [switch]$Bundle,
    [switch]$App
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Push-Location (Split-Path -Parent $PSScriptRoot)

try {
    $name = 'ex_tbp_monty'
    $release = "_build/desktop/rel/$name"
    # Two components, not `bin/server.bat`: `Join-Path` keeps the forward slash
    # inside its second argument, and a batch file started that way hands its own
    # `%~dp0` - slashes and all - to the release's launcher, whose `%~dp0..` then
    # reads `…\bin/..` and `erl` answers "cannot get boot file".
    $launcher = Join-Path $release "bin\$name.bat"
    $sidecar = Join-Path $release 'bin\server.bat'
    $window = 'src-tauri/target/debug/ex-tbp-monty-desktop.exe'

    # Bundling is a separate config, merged only for `-Bundle`/`-App`:
    # `bundle.active` in the main config makes `cargo build` — the debug window
    # this script opens every run — fail in tauri-build's resource phase, and
    # the debug window has no use for a bundle. Windows has its own file because
    # the target is `nsis` where macOS asks for `app`.
    $bundleConfig = Join-Path $PWD 'src-tauri/tauri.bundle.windows.json'
    $bundleDir = 'src-tauri/target/release/bundle/nsis'

    $script:steps = 0

    function Invoke-Step {
        param([string]$What, [scriptblock]$Do)

        $script:steps++
        $started = Get-Date
        Write-Host "[$($script:steps)] $What"

        & $Do
        $code = $LASTEXITCODE
        if ($null -ne $code -and $code -ne 0) {
            Write-Host "[$($script:steps)] failed with exit code $code"
            exit $code
        }

        Write-Host "[$($script:steps)] ok in $([int]((Get-Date) - $started).TotalSeconds)s"
    }

    function Test-Requirement {
        param([string]$Command, [string]$What)

        if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
            Write-Host "missing: $Command - $What"
            exit 69
        }
    }

    # What a build cannot happen without, asked once here rather than discovered
    # fifteen steps in as "no such file". `npm` is as load-bearing as the other
    # two: `assets/js` imports packages, and esbuild resolves them from
    # `assets/node_modules`.
    Test-Requirement mix 'Elixir and Mix - https://elixir-lang.org/install.html'
    Test-Requirement cargo 'the Rust toolchain - https://rustup.rs'
    Test-Requirement npm 'Node.js - https://nodejs.org (the scripts import npm packages)'

    # Building every time is deliberate. The window carries its own copy of the
    # release (`bundle.resources` in tauri.bundle.windows.json, refreshed by
    # `cargo build`), so an Elixir-only change that skipped the release step
    # would leave the window starting the copy it made hours earlier.
    $env:MIX_ENV = 'desktop'

    # Hex and rebar are what `mix deps.get` runs on, and a machine that has never
    # built an Elixir project has neither — the fetch then stops to ask whether
    # to install them, and a prompt inside a script is a hang.
    Invoke-Step 'installing Hex and rebar (a fresh machine has neither)' {
        mix local.hex --force --if-missing
        mix local.rebar --force --if-missing
    }

    Invoke-Step 'fetching the dependencies' { mix deps.get }

    # Before the stylesheet, and that is the whole point: the app's compiler is
    # what writes `_build/desktop/phoenix-colocated/ex_tbp_monty/colocated.css`,
    # and `assets/css/app.css` imports it by name. A fresh runner had no such
    # file and tailwind said "Can't resolve 'phoenix-colocated/…'" — the shell
    # twin has compiled here since it was written, which is why only this one
    # failed.
    Invoke-Step 'compiling the desktop build (it writes the colocated CSS the stylesheet imports)' {
        mix compile
    }

    # The native kernels are gitignored build products in `priv/native`, written as
    # a side effect of compiling the modules that `use Rustler`. A `_build`
    # restored from CI's cache can carry up-to-date beams and an empty
    # `priv/native`, and the release is then assembled without them: it starts and
    # dies at `KdTreeNif` with "Failed to load NIF library". Forced only when they
    # are missing, and `priv/native` is deliberately not cached — a stale copy that
    # disagrees with the beams is how that happened.
    #
    # Rustler writes `kd_tree_nif.so` everywhere but Windows, where a shared
    # library is a `.dll`: the kernels are whatever this platform spells them.
    if (-not (Get-ChildItem priv/native -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.so', '.dll' })) {
        Invoke-Step 'building the native kernels (a cached build can be missing them)' {
            mix compile --force
        }
    }
    Invoke-Step 'checking the asset toolchain (installs it once, then finds it)' {
        mix assets.install --if-missing
    }

    # `npm` is `npm.cmd` on Windows, and `mix cmd` starts the program it is
    # given directly — which a `.cmd` is not: Elixir's `System.cmd` fails on one
    # with `:eacces`, the same reason the window launches its sidecar through
    # `cmd /C call`. Going through `cmd` is what makes it a program to start.
    Invoke-Step 'installing the packages the scripts import' {
        Push-Location assets
        try { cmd /C npm ci } finally { Pop-Location }
    }

    # The screens are the server's, so the bundle has to be the server's too:
    # CSS, the LiveView client, and the colocated hooks each screen carries. A
    # release ships whatever `priv/static` holds and never builds it.
    Invoke-Step 'building the stylesheet' { mix tailwind ex_tbp_monty --minify }
    Invoke-Step 'building the scripts' { mix esbuild ex_tbp_monty --minify }
    Invoke-Step 'writing the build stamp (the footer reads it)' { mix build.info }

    Invoke-Step 'building the desktop release (a no-change run only reassembles it)' {
        mix release --overwrite
    }

    # Asked, rather than assumed: a release with no NIFs is a window that cannot
    # start, and this is the last moment the build can say so with a sentence
    # instead of shipping it. Only `priv/native` counts: Erlang's own
    # `priv/lib/crypto.so` would otherwise answer for a kernel that is not there.
    #
    # The condition is one line because Windows PowerShell 5.1 will not continue
    # a statement after a trailing `-and`.
    $kernels = Get-ChildItem "$release/lib" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.so', '.dll' -and $_.Directory.Name -eq 'native' -and $_.Directory.Parent.Name -eq 'priv' }
    if (-not $kernels) {
        throw "the release carries no native kernels: $release has no priv/native/*.so and no *.dll — see docs/desktop.md"
    }

    # No peers to cluster with: a distributed release has a fixed node name, so a
    # second launch fails with "the name ... is in use by another Erlang node"
    # and dies before it says where it listens — which the window reports as
    # "the sidecar stopped before it said where it listens".
    $env:RELEASE_DISTRIBUTION = 'none'

    if ($Where) {
        Invoke-Step 'reading where the data is' {
            & $launcher eval @'
alias Monty.Paths

IO.puts("folder:      #{Paths.root()}")
IO.puts("database:    #{Paths.database()}")
IO.puts("data:        #{Paths.data()}")
IO.puts("models:      #{Paths.models()}")
IO.puts("memory:      #{Paths.libraries()}")
IO.puts("runs:        #{Paths.artifacts()}")
'@
        }

        exit 0
    }

    if ($InBrowser) {
        Write-Host ''
        Write-Host "serving the window's own server in this terminal: it prints its address"
        Write-Host 'below, and Ctrl-C stops it. Same routes as the window, one server.'
        Write-Host ''
        & $sidecar
        exit $LASTEXITCODE
    }

    if ($Bundle -or $App) {
        # `cargo tauri` is the Tauri CLI, a cargo subcommand of its own.
        # Installing it takes a few minutes once per machine; failing at the last
        # step with "no such command" throws away the build that came before it.
        if (-not (Get-Command cargo-tauri -ErrorAction SilentlyContinue)) {
            Invoke-Step 'installing the Tauri CLI (a fresh machine has none)' {
                cargo install tauri-cli --version '^2' --locked
            }
        }

        # The release is copied into the bundle by tauri-build, and it copies
        # *over* whatever is there: the previous copy keeps the release's own
        # modes, so the copy fails with "Permission denied (os error 13)" on
        # every run after the first. Removing the copy is cheaper than making
        # thousands of files writable, and nothing is lost — it is a copy of
        # `_build/desktop/rel`.
        Remove-Item -Recurse -Force 'src-tauri/target/release/rel' -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force 'src-tauri/target/release/bundle' -ErrorAction SilentlyContinue

        Invoke-Step 'building the installer bundle (a minute warm, six cold — the window is rebuilt in release)' {
            cargo tauri build --config $bundleConfig
        }

        $installer = Get-ChildItem -Path $bundleDir -Filter '*-setup.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -eq $installer) {
            Write-Host "the build said it finished and there is no installer in $bundleDir"
            exit 1
        }

        Write-Host ''
        Write-Host $installer.FullName
        Write-Host "the window without an installer: $PWD\src-tauri\target\release\ex-tbp-monty-desktop.exe (next to rel\)"

        if ($App) {
            Write-Host ''
            Write-Host 'opening the app. Close its window to come back here.'
            Write-Host ''
            Start-Process 'src-tauri\target\release\ex-tbp-monty-desktop.exe' -Wait
        }

        exit 0
    }

    # The default: the debug window, run from this checkout.
    Invoke-Step 'building the window (a minute warm)' { cargo build --manifest-path src-tauri/Cargo.toml }

    Write-Host ''
    Write-Host 'opening the window. Close it to come back here; Ctrl-C leaves it running.'
    Write-Host ''
    & $window
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
