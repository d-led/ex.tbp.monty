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

| piece                                                                       | where                                                                       |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| the folder, and the names Monty's tooling reads underneath it               | `lib/monty/paths.ex`                                                        |
| the build: a `:desktop` env with its own supervision start                  | `mix.exs` (`elixirc_paths/1`, `application_module/1`), `config/desktop.exs` |
| what a launch decides — paths, the repo, the salt, loopback                 | `config/runtime.exs` (the `:desktop` block)                                 |
| the port it prefers, how to change it, and the line on stdout that names it | `lib_desktop/desktop/server.ex`                                             |
| the start itself: the server's tree, announced                              | `lib_desktop/desktop/application.ex`                                        |
| what stops it: the window's pipe, and the process that ran it               | `lib_desktop/desktop/parent_watch.ex`                                       |
| the window: a process supervisor with a webview                             | `src-tauri/src/main.rs`, `src-tauri/tauri.conf.json`                        |
| build both halves, open one                                                 | `scripts/start-desktop.sh`                                                  |
| the icons, from the two SVG masters, and the favicon                        | `scripts/make-icons.sh`                                                     |

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
7. `scripts/install-desktop.sh` with `EX_TBP_MONTY_BASE_URL` pointed at that
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
installable thing, CI that uploads it, and an installer that fetches it — because
it needs no release to exist before somebody can try the app:

1. `scripts/package.sh` builds what a person can install, for one platform at a
   time, into `artifacts/<platform>/`:

   | file                          | what it is for                                                                                                                                       |
   | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
   | `Monty on the BEAM.app`       | the bundle itself                                                                                                                                    |
   | `ex-tbp-monty-osx-arm64.zip`  | what `install-desktop.sh` downloads and CI uploads; made by `ditto`, because an `.app` holds symlinks and executable modes that a plain zip flattens |
   | `monty-on-the-beam-0.1.0.pkg` | double-click, app appears in `/Applications` (see below)                                                                                             |
   | `monty-on-the-beam-0.1.0.dmg` | the by-hand form: drag it into `/Applications`                                                                                                       |

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
   is a different thing, and that is what `install-desktop.sh` does — at their own
   privilege, on a file they chose to install.

2. CI's `desktop` job runs it on a runner of the architecture it ships to and
   uploads the zip as `ex-tbp-monty-osx-arm64`, for ninety days.
3. `scripts/install-desktop.sh` downloads the newest build of `main` from
   `nightly.link`, expands it, and puts the app in `~/Applications`.
4. A `v*` tag runs `desktop-release`, which attaches the same zip to a GitHub
   release — an artefact expires, a release does not.

The app is 550 MB uncompressed (324 MB zipped, 404 MB as a disk image) and that
is not a mistake: it carries the Elixir release, the BEAM, the embedded Python
and the wheels a MuJoCo world renders with. Nothing is downloaded on first launch
except Monty's own data.

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

## What is still open

- **Signing and notarisation.** The `.app` is unsigned, so the first launch needs
  right-click → Open (the installer clears the quarantine flag, which is what
  makes that possible at all). `ElixirKit.Release.codesign/1` plus Tauri's
  `APPLE_SIGNING_IDENTITY`/`APPLE_ID`/`APPLE_TEAM_ID` is the path; neither can be
  done without a paid Apple Developer certificate.
- **Only macOS arm64 is built.** Linux needs `libwebkit2gtk-4.1-dev` and friends
  on the runner, Windows needs MSVC and WebView2, and neither has been tried — so
  neither is claimed. Each is one `include:` in the `desktop` job when it is.
- **The prerequisites download** is on by default in the window (`prefetch: true`)
  and lands under the folder above. Nothing has been run end to end from a
  _fresh_ folder yet: a first launch downloads ~543 MB and then exports the
  memory, both in the background.
- **A run in the window** (an experiment to its conclusion) has not been done;
  it is the same binary as the image, so what remains is patience, not wiring.
