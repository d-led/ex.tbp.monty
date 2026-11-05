# The desktop deployment

Where this stands: **the window builds, and it serves the studio unchanged.** The
chain is `src-tauri` → `_build/desktop/rel/ex_tbp_monty/bin/server` → the
endpoint on a loopback port → a webview. `scripts/start-desktop.sh` builds both
halves and opens it; `--in-browser` serves the same release in a terminal and
`--where` prints the folder it keeps its data in.

No screen was added or rewritten. Every page the window shows is the page the
server serves, because a page that needed a second version for the desktop would
be a page that had stopped being the same application.

## Why it is possible now

Until `f0ed29b` the application needed a database server to boot, which a
desktop app cannot ask of a user. The database is now a file by default — and
that only became _true_ in `3296e41`, which is worth knowing before trusting it:
until then `repo_module/0` answered a written-in default of Postgres and
`runtime.exs` set `:repo` from `repo_module/0`, so the default echoed itself and
a release with no `DATABASE_URL` started Postgres against a file path. The
symptom was a migration that never ran and an image that never became healthy.

| piece                                                                                                                                                | where                                                                  |
| ---------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| the file's path — `SQLITE_PATH`, else `<application data>/ex_tbp_monty.db`                                                                           | `lib/ex_tbp_monty/database.ex` (`sqlite_path/0`), `lib/monty/paths.ex` |
| `repo_module/0` — a configured `:repo` wins (`dev` and `test` name Postgres), else `DATABASE_URL` decides                                            | `lib/ex_tbp_monty/database.ex:27`                                      |
| `repo/0`, `oban_engine/0` — the same predicate, so the module and its configuration cannot disagree                                                  | `lib/ex_tbp_monty/database.ex:33,47`                                   |
| the SQLite branch — `pool_size: POOL_SIZE` or 5, `busy_timeout: 30_000`, no `journal_mode` (exqlite's default is WAL, so the sidecars appear anyway) | `lib/ex_tbp_monty/database.ex:87`                                      |
| two repos and one delegating `ExTbpMonty.Repo`, because `Ecto.Repo`'s adapter is fixed at compile time                                               | `lib/ex_tbp_monty/repo/*.ex`                                           |
| `migrate/0` migrates whichever store the release was given, and `ecto_repos` is set to it                                                            | `lib/ex_tbp_monty/release.ex`, `config/runtime.exs:74`                 |

## What exists now

| piece                                                                       | where                                                                                   |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| the folder, and the names Monty's tooling reads underneath it               | `lib/monty/paths.ex`                                                                    |
| the build: a `:desktop` env with its own supervision start                  | `mix.exs` (`elixirc_paths/1`, `application_module/1`), `config/desktop.exs`             |
| what a launch decides — paths, the repo, the salt, loopback                 | `config/runtime.exs` (the `:desktop` block)                                             |
| the port it prefers, how to change it, and the line on stdout that names it | `lib_desktop/desktop/server.ex`                                                         |
| the start itself: the server's tree, announced                              | `lib_desktop/desktop/application.ex`                                                    |
| what stops it: the window's pipe, and the process that ran it               | `lib_desktop/desktop/parent_watch.ex`                                                   |
| the window: a process supervisor with a webview                             | `src-tauri/src/main.rs`, `src-tauri/tauri.conf.json`                                    |
| build both halves, open one                                                 | `scripts/start-desktop.sh`                                                              |
| the tools the build asks for, and installs the ones it can                  | `scripts/start-desktop.sh` (`require`, Hex, rebar, `npm ci`, `cargo install tauri-cli`) |
| the icons, from the two SVG masters, and the favicon                        | `scripts/make-icons.sh`                                                                 |

The two drawings in `src-tauri/icons/` are the only icon sources. The detailed
one carries circuit traces and is used from 64 px up; at 16 and 32 px those
traces collapse into a smudge, so the smaller sizes come from the simplified
drawing. `scripts/make-icons.sh` renders the `.icns`, the `.ico`, the PNGs and
`priv/static/favicon.ico`. Two runs with the same tools write the same bytes, so
a run that changes nothing leaves the working tree alone; a different ImageMagick
build re-encodes the same pixels to different bytes, which shows up in `git`
without any change to the picture.

`lib_desktop/` is compiled for `MIX_ENV=desktop` and for the tests, so `lib/`
never names a `Desktop.*` module and nothing dev or prod ships contains this
code.

## The port

The app answers on **42_800**, the same number every launch, because the MCP
endpoint on `/mcp/config` is a URL a person pastes into a client once and a
client that has to be re-pointed is not configured. Two ways to move it, neither
of which needs a rebuild:

- `MONTY_DESKTOP_PORT=42_900 …/bin/server` for a script or a service.
- one line in `~/Library/Application Support/ex-tbp-monty/desktop_port` for the
  person who double-clicks the app and has no shell to export anything from.

A setting that is not a port is logged and ignored — refusing to start over a
typo in a file nobody asked you to write would be the worse trade. And when the
port itself is taken, by a second copy of the app or by anything else, the
operating system picks one instead and the announcement carries it: a fixed port
alone would make the second copy the one that fails.

## The template that was copied

`/Users/dmitryledentsov/src/confluence_phx_mirror` ships a Phoenix app as a Tauri
window over an Elixir release, with SQLite under the OS's per-user data
directory. Same problem one size smaller, already solved. What was taken, and
what had to differ:

**(a) Where the data is — their `lib_desktop/desktop/settings.ex`.**
`default_root/0` is `:filename.basedir(:user_data, @app_name)`, which is the
whole of the platform dependence: `~/Library/Application Support/<app>` on
macOS, `~/.local/share/<app>` on Linux, `%APPDATA%\<app>` on Windows. Ours is
`Monty.Paths`, without the settings file: this application has nothing to
remember about the workspace, because its workspace _is_ the folder.

**(b) The build shape — their `mix.exs:70,73` and `config/desktop.exs`.**
`elixirc_paths(:desktop)` adds `lib_desktop/` and `application_module(:desktop)`
starts a different module, so dev, test and prod never compile the desktop code.
One difference worth keeping: their `config/desktop.exs` computes the data
folder at _compile_ time, which bakes the build machine's home directory into
the release. Ours names the folder at run time (`config/runtime.exs`,
`ExTbpMonty.Repo.SQLite.init/2`), so a window built on one machine finds its own
data on another.

**(c) The window — their `src-tauri/src/main.rs`.** Tauri is a window and a
process supervisor and nothing else: it starts the release as a sidecar with
`RELEASE_DISTRIBUTION=none`, reads the address the release prints on stdout,
points a webview at it, and kills the child on `RunEvent::Exit`.

**(d) Two things a repository must not contain.** A constant `SECRET_KEY_BASE`
is a secret in a repository; the desktop application generates one per launch
instead, because the window is one reader on loopback. We have no local-admin
shortcut to mirror, so there is nothing to disable.

**(e) The prose precedes the code.** This file is that prose.

## What this application has to put in application data

Every path is now answered by `Monty.Paths`, environment variable first, the
folder above otherwise — so the image, CI and the `mix` tasks keep working with
the names they already use.

- the database file — `ExTbpMonty.Database.sqlite_path/0` → `Monty.Paths.database/0`
- the artefacts a run leaves beside its record — `Monty.Studio.Artifacts`, given
  `Monty.Paths.artifacts/0` by the desktop runtime
- the prerequisite bundles, ~543 MB of YCB objects plus the pretrained memory —
  `Monty.Prerequisites.root_path/1` (`MONTY_DATA` → `~/tbp/data`,
  `MONTY_MODELS` → `~/tbp/results/monty/pretrained_models`, `MONTY_LOGS` →
  `~/tbp/results/monty/projects`)
- the memory export — `:monty_libraries_dir` (`MONTY_LIBRARIES`, else
  `<data>/libraries`), `config/runtime.exs:80`

One decision, taken deliberately: Monty's own three variables keep Monty's
defaults in a checkout, because a developer's `~/tbp` is where Monty's tooling
already put those files and this port reads the same tree. The desktop boot
_names_ the folder once in `config/runtime.exs` — `MONTY_DATA`,
`MONTY_MODELS`, `MONTY_LOGS`, `MONTY_LIBRARIES`, `SQLITE_PATH`, `WANDB_DIR` —
and everything downstream, including Monty's YAML resolvers
(`${oc.env:MONTY_DATA}`) and the embedded Python world, reads the same answer.
An exported variable still wins; `Monty.Paths` is where that is decided.

## The hard parts, in order of risk

1. **Python and MuJoCo per OS.** The engine is a port to an interpreter
   (`MONTY_PYTHON`, `lib/monty/simulators/port/*`). The image installs
   `libegl1 libgl1 libosmesa6` and sets `MUJOCO_GL` (`Dockerfile:163,173`);
   macOS needs either a bundled interpreter or a GL context it can actually
   open, and Windows is a third story. The window inherits the interpreter
   behaviour of the app: `config/pythonx.exs` is compile-time, so the desktop
   build carries its own. Not exercised yet on a machine that has no Python
   toolchain — this Mac has one.
2. **Signing and notarisation** on macOS: the sidecar, the NIFs
   (`native/kd_tree_nif`, `native/matcher_nif`) and the hardened runtime all have
   to agree. They already build per platform, so this is bundle-and-sign.
3. **Migrations.** `priv/repo/migrations/20261104090000_wrap_run_json_columns.exs`
   rewrites `log` and `timeline` with `to_jsonb` and is a no-op unless the
   adapter is Postgres. A _fresh_ SQLite file gets the JSON columns from the
   create migrations anyway, and `bin/server` migrates before it serves — so the
   window's first launch is also its first migration.
4. **The SQLite options stay the container's.** exqlite's default journal mode
   is WAL, `pool_size: 5` and `busy_timeout: 30_000`, and the desktop build
   inherits them unchanged. That is deliberate: the other project's tool hung
   with `pool_size: 1` while the endpoint and a background job each wanted a
   connection. One reader is not the same thing as one connection.
5. **The secret and the local admin surface** — see (d). This application has
   no second reader to promote, so only the secret applies.

## What was verified, and how

The desktop path is checked by starting it, because what matters is that the
release boots with nothing configured. The one decision with alternatives in it
— which port — is specified by tests instead, which is why `:test` compiles
`lib_desktop`.

1. `MIX_ENV=desktop mix compile --warnings-as-errors` — clean.
2. `MIX_ENV=desktop mix ecto.migrate` — created
   `~/Library/Application Support/ex-tbp-monty/ex_tbp_monty.db` and applied every
   migration to it. (This is what `ExTbpMonty.Repo.SQLite.init/2` is for: `mix
ecto.*` reads the repository list before `runtime.exs` has run.)
3. `bin/server` with **only** `RELEASE_DISTRIBUTION=none` (and `PREFETCH=0`, so
   the verification did not start a 543 MB download): `Migrations already up`,
   `Running ExTbpMontyWeb.Endpoint … at 127.0.0.1:<port>`,
   `desktop ui: http://127.0.0.1:<port>/`, `/health` 200, `/experiments` 200,
   `/assets/css/app.css` 200.
4. `cargo build --manifest-path src-tauri/Cargo.toml` — the window compiles.
5. `scripts/start-desktop.sh` — the window opens, its sidecar is the release
   above, and the webview asks for `/` and gets 200. The window's title is
   "Monty on the BEAM · Monty studio": the same page a browser gets.
6. `scripts/start-desktop.sh --bundle` — a 518 MiB `Monty on the BEAM.app`, and
   `Contents/Resources/rel/ex_tbp_monty/bin/server` inside it starts and answers
   `/health` 200.
7. `scripts/run-desktop.sh` with `EX_TBP_MONTY_BASE_URL` pointed at that
   artefact — it unzips both layers and puts the app where it says. The
   installed copy, run from `/tmp`, launches its **own** server out of
   `Contents/Resources`: the bundle carries everything it runs.
8. A window that is **force-quit** still takes its server with it. Closing the
   window runs `RunEvent::Exit`; `kill -9` runs nothing, so the window pipes
   stdin to the release and the release reads it
   (`IO.binread(:stdio, :eof)` in `ExTbpMonty.Desktop.Application`): the pipe
   closing is the window being gone, and the server stops. Checked by killing a
   window and watching its sidecar's port go from `200` to connection refused —
   `RunEvent::Exit` alone left it listening.
9. The port: `test/desktop/server_test.exs` pins the preferred number, both
   overrides, a setting that is not a number, and the fallback when the port is
   held. Then two releases started at once: the first announced 42_800, the
   second said the port was taken and announced one the operating system picked,
   and both answered `/health` 200. Setting `MONTY_DESKTOP_PORT` and writing
   `desktop_port` were each checked by watching the announcement change.
10. Nothing is left behind. The window holds its server's standard input open, so
    the pipe closing stops it, and `RunEvent::Exit` stops it on the tidy path.
    The case those two miss is a server started by hand — four of them once ran
    for hours after their shells had gone, holding port 42800 and the database,
    with no tray icon to reveal them. `ExTbpMonty.Desktop.ParentWatch` polls the
    pid that started the server and stops the VM when it is gone: checked by
    starting the release under `sh`, killing `sh` with `kill -9`, and watching
    the server answer `/health` 200 and then exit about two seconds later.
    `test/desktop/parent_watch_test.exs` covers the same decision.

## Shipping: what a person downloads

The shape is the one `worksheet.net` uses — a packaging script that produces the
bundle, CI that uploads it, and a script that fetches, unpacks and runs it —
because it needs no release to exist before somebody can try the app:

1. `scripts/package.sh` builds what a person downloads, for one platform at a
   time, into `artifacts/<platform>/`:

   | file                          | what it is for                                                                                                                                   |
   | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
   | `Monty on the BEAM.app`       | the bundle itself                                                                                                                                |
   | `ex-tbp-monty-osx-arm64.zip`  | what `run-desktop.sh` downloads and CI uploads; made by `ditto`, because an `.app` holds symlinks and executable modes that a plain zip flattens |
   | `monty-on-the-beam-0.1.0.pkg` | double-click, app appears in `/Applications` (see below)                                                                                         |
   | `monty-on-the-beam-0.1.0.dmg` | the by-hand form: drag it into `/Applications`                                                                                                   |

   `--no-dmg`, `--no-zip` and `--no-pkg` skip any of them; `all` means "the
   platform this machine is", and a platform it is not is refused rather than
   faked. The build itself is `scripts/start-desktop.sh --bundle` — the
   packaging script has no second copy of those steps.

   The `.pkg` installs without anybody dragging anything, and it arrives
   **without the quarantine flag** — not because a script strips it, but because
   the flag belongs to the file that was _downloaded_, and here the installer,
   not a browser, writes the payload. What remains is Gatekeeper assessing the
   `.pkg` itself, which is why an unsigned package is still right-click → Open.

   A `postinstall` script running `xattr` on the installed app is the trick that
   circulates for this. It is not needed for a payload installed this way, and its
   usual form does not even run: macOS `xattr` takes `-c -d -l -p -w -s -x` and
   **no `-r`**, so `xattr -rd com.apple.quarantine` fails with "option -r not
   recognized". Stripping the flag from an app that a person unpacked themselves
   is a different thing, and that is what `run-desktop.sh` does — at their own
   privilege, on a file they chose to unpack.

2. CI's `desktop` job runs it on a runner of the architecture it ships to and
   uploads the zip as `ex-tbp-monty-osx-arm64`, for ninety days.
3. `scripts/run-desktop.sh` (`run-desktop.ps1` on Windows) takes the newest build
   of `main` from `nightly.link`, expands it into `./ex-tbp-monty-<platform>/`
   beside the download, and opens it. It copies nothing anywhere and registers
   nothing — no `PATH` entry, no menu entry, no registry key: the folder _is_ the
   application, and deleting it is the whole of getting rid of it. Running the
   script again opens what is there; `--update`
   (`-Update`, or `$env:EX_TBP_MONTY_UPDATE = 1` through the one-liner) takes the
   newest build first. The `.pkg` and the NSIS setup in the same download are for
   a person who wants an entry in `/Applications` or under "Apps & features" and
   would rather the OS tracked it.

   The two forms of the one command:

   ```bash
   # macOS and Linux
   curl -fsSL https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/scripts/run-desktop.sh | bash
   ```

   ```powershell
   # Windows
   powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/scripts/run-desktop.ps1 | iex"
   ```

   **The one-liner is tested by CI, on the platform it runs on.** Each `desktop`
   job wraps its own artefacts the way `nightly.link` does, runs the script
   against that wrapper with `EX_TBP_MONTY_NO_LAUNCH` (`--no-launch`) — unpack,
   find the window, stop — and fails if the window is not where it says. That
   came from a real failure: the download is two zips (the artefact, and the
   folder zipped inside it), one `.pdb` entry in the inner one fails to extract
   with the `tar` that ships on Windows and macOS, and the script treated the
   unpacker's non-zero status as fatal while everything it needed was already on
   disk. It now judges the result — is the window there — and reports what the
   download held and what the unpacker said when it is not. The `.pdb` files are
   not shipped any more either: nineteen debug symbols, ~90 MB of the download
   for a binary nobody debugs here.

4. A `v*` tag runs `desktop-release`, which attaches the same zip to a GitHub
   release — an artefact expires, a release does not.

The app is 550 MB uncompressed (324 MB zipped, 404 MB as a disk image) and that
is not a mistake: it carries the Elixir release, the BEAM, the embedded Python
and the wheels a MuJoCo world renders with. Nothing is downloaded on first launch
except Monty's own data.

Where the interpreter is, since it is more than half of that: the release carries
`lib/pythonx-0.4.11/priv/uv/` — `python/` is the CPython 3.13 build uv fetched
(47 MB) and `project/` is the environment it built from `config/pythonx.exs`
(250 MB: MuJoCo, NumPy, `numpy-quaternion` for the `wxyz` rotations, and wandb).
uv builds it at **compile** time, once per platform, which is the real reason a
release does not cross-compile: the desktop bundle carries the same tree at
`Contents/Resources/rel/ex_tbp_monty/lib/…` on macOS, beside the window on Linux,
and under `rel\` on Windows.

## ElixirKit, and what its guide settled

[`elixirkit`](https://elixirkit.hexdocs.pm/tauri.html) (Livebook's desktop
library) documents the same architecture — Tauri as window and supervisor, an
Elixir release inside `Contents/Resources`, `beforeBuildCommand` to build it.
Reading it after the fact confirmed the shape and named four things worth taking:

- **`ElixirKit.Release.codesign/1`** is a release step that signs the embedded
  BEAM and its NIFs — the part Tauri does not do for us. That is the signing gap
  below, and this is what to use when there is a Developer ID to sign with.
- **The single-instance plugin** — their guide calls it crucial on Windows. We
  have nothing stopping a second copy, and two copies are two servers on one
  SQLite file.
- **The updater plugin** — how an installed copy gets newer than the day it was
  installed, without another trip through the installer.
- **Their CI matrix** (`macos-15`, `macos-15-intel`, `ubuntu-22.04`,
  `windows-2022`, one runner each) is the shape to grow our one-line matrix into.

What was deliberately not taken:

- **The PubSub handshake.** Their window is created when Elixir broadcasts
  `ready` over an `ElixirKit.PubSub` bridge. Ours prints one line,
  `desktop ui: <url>`, and the window reads it: no extra dependency in Elixir or
  Rust, and the address is what the window needs anyway. The bridge earns its
  keep when Elixir has to drive Rust (tray, deep links, quit from Elixir); we
  have none of that yet.
- **Their secret and port.** The guide hardcodes `SECRET_KEY_BASE` and `PORT` and
  footnotes both. We generate the salt per launch and ask the OS for a free port
  — which is the footnote's advice taken.
- **`beforeBuildCommand`.** Their release is built by Tauri's build hook. Ours is
  built by `scripts/start-desktop.sh --bundle`, so the same steps run locally, in
  CI and for `--in-browser`, and a missing asset is a script error naming the
  step rather than a Tauri error.

## Windows

The same jobs exist as PowerShell, because a Windows machine has no `bash` and a
`.ps1` is what a person there can run — with the usual caveat that an unsigned
script needs `powershell -ExecutionPolicy Bypass -File scripts\package.ps1`:

| piece                                              | where                                               |
| -------------------------------------------------- | --------------------------------------------------- |
| build both halves, open one                        | `scripts/start-desktop.ps1`                         |
| what a person can install: folder, zip, NSIS setup | `scripts/package.ps1`                               |
| the release's entry point, in batch                | `rel/overlays/bin/server.bat`, and its two siblings |
| the bundle Tauri builds there (`nsis`, not `app`)  | `src-tauri/tauri.bundle.windows.json`               |

Two things had to exist before a Windows build could start its own server:

- **`bin\server.bat`.** The overlays are shell scripts, Windows has no shebang,
  and the release's own launcher there is `bin\ex_tbp_monty.bat`. The batch files
  do what their shell twins do, in the same order: create `WANDB_DIR`, migrate
  unless `MIGRATE_ON_BOOT=false`, then `PHX_SERVER=true` and start.
- **`cmd /C call "…\bin\server.bat"`.** The window starts a `.bat`, which is a
  file `cmd.exe` reads rather than a program: `Command::new` on it fails with
  "not a valid Win32 application". The `call` is not decoration either — `cmd`
  alone splits a quoted path at its first space, and the bundle's path has one
  (`…\Monty on the BEAM\…`). `CREATE_NO_WINDOW` is the third part: a GUI-subsystem
  program that spawns `cmd` draws a console for it, which is the black flash. All
  three are `#[cfg(windows)]` in `src-tauri/src/main.rs`, so the macOS path is
  the same code it was.

**Built by CI, and not yet started.** A `windows-2022` row builds it, and the run
at `ae325a1` is the first to upload `ex-tbp-monty-win-x64.zip` (264 MB) — after
two attempts that failed on defects only Windows has: first `npm` being `npm.cmd`
(Elixir's `System.cmd` cannot start one; it failed with `:eacces`), then the
stylesheet being built before anything compiled the application, so the colocated
CSS it imports did not exist yet. The second was reproduced without Windows at
all. What no runner can answer is what happens after launch: `mix release` laying
down `bin\ex_tbp_monty.bat`, and MuJoCo, which defaults to WGL on Windows —
`rel/env.sh.eex` sets `MUJOCO_GL=osmesa` for Linux and `rel/env.bat.eex` has no
equivalent, so a MuJoCo experiment is the first thing to watch there.

**Started, and it failed — twice, both fixed.** The first launch showed a console
window that flashed and vanished: a release build on Windows was a _console_
program (`windows_subsystem` unset), and a startup failure then takes its own
sentence with it. Two changes:

- The window is a window. `#![cfg_attr(not(debug_assertions), windows_subsystem =
"windows")]`, and what a failure says goes to
  `<application data>/ex-tbp-monty/window.log` — `%APPDATA%` on Windows,
  `~/Library/Application Support` on macOS, `$XDG_DATA_HOME` or `~/.local/share`
  on Linux — and on Windows to a message box as well, because that release build
  has no console at all and `stderr` goes nowhere. (A macOS `.app` launched from
  the Finder has no terminal either, so there the log is the only trace.) The
  sidecar's own `stderr` is drained by a thread and the last lines are appended to
  the failure, so "the sidecar stopped before it said where it listens" now
  arrives with the reason underneath it.
- **A path handed to `cmd` must not mix separators.** `resources.join("rel/ex_tbp_monty").join("bin/server.bat")`
  produced `…\rel/ex_tbp_monty\bin/server.bat`; Windows accepts it, but `%~dp0`
  inside the batch file inherits those slashes, so the launcher's `%~dp0..` became
  `…\bin/..` and `erl` answered **`cannot get boot file`** about a `start.boot`
  under a path that does not exist. The window now joins one component at a time
  and normalises to `\` on Windows, and the overlays take their own folder from
  `%~dp0`, normalise the slashes **in it**, and call the launcher from that
  (`set "HERE=%~dp0"`, `set "HERE=%HERE:/=\%"`) — so a caller cannot reintroduce
  them, and the folder comes from the file rather than from wherever the process
  was started. `*.bat` is stored with `eol=crlf` (`.gitattributes`) because
  `cmd` is a CRLF parser and the overlays are copied into the release unchanged.
- **Nothing assumes a working directory.** A Windows process is started from
  wherever its shortcut, task or shell was: the overlays use `%~dp0`, the window
  spawns the sidecar with the release's own folder as its working directory
  (`Command::current_dir`), and the development fallback finds `_build/desktop/rel`
  from the executable's place in the checkout instead of from `../`. An earlier
  version used `%CD%` for the overlay's calls, which is the directory _after_ a
  `cd /d` — and `cd /d` cannot honour a UNC path at all, so it quietly stayed
  where it was.
- **A release that never speaks is reported, not waited on.** The window waits at
  most forty-five seconds for `desktop ui: <url>` — a release with its database
  already answers in about two, and a first launch adds the migrations; after
  that the window stops the sidecar and shows what the release said. Without a bound, a release whose runtime is missing
  or whose launcher cannot find its boot file looks exactly like a slow one, and a
  person gets neither a window nor an explanation.
- **Windows has two PowerShells and they are not the same language.**
  `run-desktop.ps1` parsed cleanly in PowerShell 7 — what the runner adds — and
  Windows PowerShell 5.1, which is what a person has, answered "Missing closing
  `}`" about an `else` on a line of its own. The scripts are written in the
  plainer dialect now (ASCII only, `} else {` on one line, nothing hanging on an
  operator or a pipe), and `scripts/check-syntax.ps1` parses every `.ps1` with
  whichever PowerShell runs it: the desktop job runs it under **both** before it
  packages anything, because that takes a second and the packaging takes twenty
  minutes.
- **A release without its native kernels starts and dies.** `priv/native/*.so`
  are gitignored build products of `use Rustler`, written as a side effect of
  compiling those modules; CI caches `_build` and not them, so a warm cache can
  hand back up-to-date beams and an empty folder, and `mix release` then assembles
  a release whose `KdTreeNif` cannot load ("Failed to load NIF library"). The
  build forces a compile when the kernels are missing and refuses to finish a
  release that carries none, and the boot check below is what found it — on the
  Linux and Windows runners, the first time that check ran.
- **The release a bundle carries is started on every platform.**
  `scripts/boot-check.sh` starts the entry point the bundle holds — `bin/server`
  under `Contents/Resources/rel/…` in the `.app`, `rel/ex_tbp_monty` beside the
  window otherwise — asks `/health`, then asks `/prerequisites`, and prints what
  the release said if either never answers. The page is asked because a release
  can be alive and still have nothing to say about the disk it writes to: it did
  on Windows, while `df` — a program that platform does not have — was how the
  room was read, and the page said "the operating system did not say how much
  room is left". The `desktop` job runs this right after packaging, which is the
  only place a Windows release is started on Windows, and runs the window's
  three unit tests there too: the `#[cfg(windows)]` path code is compiled by
  that job and nowhere else.- **The window itself is opened, on all three platforms.**
  `scripts/smoke-window.sh` starts the executable a person downloads and waits
  for the page inside it to say what it drew: the layout's `Painted` hook sends
  the address, the title, the heading and the ids on the page to `/__painted`,
  and only a webview that ran the page can send that report. Every check above
  asks the _server_ a question, and one of them was green on a build whose
  window opened on nothing — that is the shape this exists for, and it found a
  real one on its first run: the window looked for the release at
  `Contents/Resources/ex_tbp_monty`, one segment short of where
  `bundle.resources` copies it, and then fell back to a path relative to the
  working directory, so a double-clicked app died naming somebody's source tree
  (`release_candidates` in `src-tauri/src/main.rs`, with tests for both).
- **The Windows installer is installed and opened.** The portable folder's `rel\`
  is put there by `scripts/package.ps1`; an _installed_ copy gets its `rel\` from
  the bundler's resource copy, so the two can differ — a download that installs
  and then crashes on start is exactly that difference. The job runs the NSIS
  setup with `/S`, finds the window where it landed, and opens it the same way.
- **The Linux tarball's release is booted, not only the staging tree.**
  The archive a person downloads is unpacked in a temporary directory and its
  `rel/ex_tbp_monty` started there: the staging folder `package.sh` assembles and
  the archive can disagree (the sibling project found an emulated container
  failing this boot in OTP's `prim_tty` NIF while the staging folder served).
- **A check that can hang is a check that hides.** The Windows run of the boot
  check printed both answers and then never ended: the cleanup waited for a
  process tree that would not die, and the job's hour ran out before anybody knew
  why. The cleanup is bounded, says so when the release survives, and the step
  itself has a ten-minute limit.

## What is still open

- **What the window does with a failure, and while it waits.** The sibling
  project (`confluence_phx_mirror`, `src-tauri/src/main.rs`, 1,523 lines against
  this one's 474) has four things this window does not, in the order they look
  worth taking:
  - a **splash window** shown at once, so the person sees something in the two
    seconds a release takes to announce its port, rather than nothing until the
    window appears;
  - a **failure page inside the window** — the sentence, the last lines the
    release said folded behind a disclosure, and a button that opens the log —
    where this shows a Windows message box and writes `window.log`;
  - a **prefilled issue URL** carrying the failure, the build and the last
    fifteen lines, so a report is one click and already has the diagnostics;
  - a **navigation guard**: only the app's own origin may load, anything else
    goes to the system browser deliberately rather than by accident. This
    window never navigates anywhere else, which is why it has not needed one
    yet, and a splash screen would be its first internal navigation.
    Their window also has ~20 unit tests for those pieces (failure
    classification, URL encoding, "where the window looks is never relative to
    the working directory"); this one has 7, and the two it gained here came from
    a real bug the window smoke found.
- **Signing and notarisation.** The `.app` is unsigned, so the first launch needs
  right-click → Open (the installer clears the quarantine flag, which is what
  makes that possible at all). `ElixirKit.Release.codesign/1` plus Tauri's
  `APPLE_SIGNING_IDENTITY`/`APPLE_ID`/`APPLE_TEAM_ID` is the path; neither can be
  done without a paid Apple Developer certificate.
- **Three platforms, and how far each is proven.** The `desktop` job builds
  macOS arm64 (the `.app`, its zip, a `.pkg` and a `.dmg`), Linux x64 (a tarball
  of the window with its release beside it, a `.deb`, and an AppImage) and
  Windows x64 (an NSIS setup and the same portable folder, zipped). The macOS
  app has been built and opened from a checkout by a person; the Linux AppImage
  has been started (see below); the Windows one is built and uploaded, and
  nobody has started it. `docs/status.md`'s own rule applies — nothing is
  claimed beyond what was run. Linux needs `libwebkit2gtk-4.1-dev`,
  `libgtk-3-dev`, `libayatana-appindicator3-dev`, `librsvg2-dev` and `patchelf`
  on the runner, which the job installs — and no FUSE, because the AppImage
  tools are run with `APPIMAGE_EXTRACT_AND_RUN`.
- **Three runtime ids, and why the other two have no build.** `osx-arm64`,
  `linux-x64` and `win-x64` are what the workflow makes. `osx-x64` and
  `linux-arm64` have no runner row and so no download, and
  `scripts/run-desktop.sh` says that before it downloads rather than reporting a
  404 as "the build does not exist yet"; `scripts/package.sh osx-x64` /
  `linux-arm64` build one on a machine of that kind. Windows has one id by
  design — `run-desktop.ps1` always takes `win-x64`, which Windows on ARM runs
  under its own emulation. Adding a row is a runner, not a code change:
  `macos-15-intel` and `ubuntu-24.04-arm` both exist.
- **The AppImage needed the release's own library path.** `linuxdeploy` stops at
  `ERROR: Could not find dependency: libmujoco.so.3.17.0`: the release carries a
  Python environment whose wheels link each other by soname, and linuxdeploy
  resolves a binary's dependencies through the loader, which knows only the
  system paths. `scripts/start-desktop.sh` runs the bundling step with
  `LD_LIBRARY_PATH` over every directory of the assembled release that holds a
  shared library, absolute (the loader resolves a relative entry against the
  process's own directory, and linuxdeploy runs from `src-tauri`), plus
  `APPIMAGE_EXTRACT_AND_RUN` for the tools themselves. Reproduced and fixed in a
  Debian container with the project's own toolchain, and then on the runner: the
  x64 AppImage is 231 MiB beside a 535 MiB `.deb` and a 525 MiB tarball.
- **The AppImage starts.** Built in that container (`aarch64`, since that is the
  host), the file was run with `xvfb-run` and no checkout in reach: the window
  came up, the release inside it answered the window's own `GET /` in 457 ms,
  and from outside the window `/`, `/health`, `/experiments` and `/runs`
  answered 200. What that does not cover is a real desktop — the window was
  drawn into a virtual one — and nothing has installed the `.deb` yet.
- **Two shapes borrow, one carries.** The tarball and the `.deb` need the
  system's WebKitGTK 4.1 and GTK 3 — the `.deb` says so itself
  (`Depends: libwebkit2gtk-4.1-0, libgtk-3-0`) and the tarball declares nothing,
  so a bare machine meets a loader error rather than a sentence. The AppImage
  carries both, which is the reason it exists; without `/dev/fuse` it needs
  `APPIMAGE_EXTRACT_AND_RUN=1`, which is what the build sets for the AppImage
  tools it runs (`scripts/start-desktop.sh`) and what a person on a machine with
  no FUSE — a container, a minimal server — has to set themselves.
- **A release keeps the runtime it was assembled with.** `erts-<version>` is
  named after the OTP version, and `mix release --overwrite` leaves an existing
  one alone, so a `_build` shared between a macOS checkout and the container
  that builds the Linux bundle handed the bundle a Mach-O `erlexec`. The window
  reports that as "the sidecar stopped before it said where it listens"; the
  sentence that names the cause, `erlexec: Exec format error`, is one process
  further down. The build asks the release's own `erl` to halt before
  assembling, and drops an erts that cannot run here.
- **The prerequisites download** is on by default in the window (`prefetch: true`)
  and lands under the folder above. Nothing has been run end to end from a
  _fresh_ folder yet: a first launch downloads ~543 MB and then exports the
  memory, both in the background.
- **A run in the window** (an experiment to its conclusion) has not been done;
  it is the same binary as the image, so what remains is patience, not wiring.
