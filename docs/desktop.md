# The desktop deployment

Where this stands: **nothing is built yet.** What exists is the reason it is now
possible, the template that already solves it one project over, and the one
module that has to come first.

## Why it is possible now

Until `f0ed29b` the application needed a database server to boot, which a
desktop app cannot ask of a user. The database is now a file by default — and
that only became *true* in `3296e41`, which is worth knowing before trusting it:
until then `repo_module/0` answered a written-in default of Postgres and
`runtime.exs` set `:repo` from `repo_module/0`, so the default echoed itself and
a release with no `DATABASE_URL` started Postgres against a file path. The
symptom was a migration that never ran and an image that never became healthy.

| piece | where |
| --- | --- |
| the file's path — `SQLITE_PATH`, else `$HOME/ex_tbp_monty.db` | `lib/ex_tbp_monty/database.ex:56` |
| `repo_module/0` — a configured `:repo` wins (`dev` and `test` name Postgres), else `DATABASE_URL` decides | `lib/ex_tbp_monty/database.ex:27` |
| `repo/0`, `oban_engine/0` — the same predicate, so the module and its configuration cannot disagree | `lib/ex_tbp_monty/database.ex:33,47` |
| the SQLite branch — `pool_size: POOL_SIZE` or 5, `busy_timeout: 30_000`, no `journal_mode` (exqlite's default is WAL, so the sidecars appear anyway) | `lib/ex_tbp_monty/database.ex:87` |
| two repos and one delegating `ExTbpMonty.Repo`, because `Ecto.Repo`'s adapter is fixed at compile time | `lib/ex_tbp_monty/repo/*.ex` |
| `migrate/0` migrates whichever store the release was given, and `ecto_repos` is set to it | `lib/ex_tbp_monty/release.ex`, `config/runtime.exs:74` |

## The template to copy

`/Users/dmitryledentsov/src/confluence_phx_mirror` ships a Phoenix app as a Tauri
window over an Elixir release, with SQLite under the OS's per-user data
directory. Same problem one size smaller, already solved. Read it in this order:

**(a) Where the data is — `lib_desktop/desktop/settings.ex`.**
`def default_root, do: :filename.basedir(:user_data, @app_name)` (line 52) is the
whole of the platform dependence: `~/Library/Application Support/<app>` on macOS,
`~/.local/share/<app>` on Linux, `%APPDATA%\<app>` on Windows. `root/0` returns a
value recorded in `settings.json`, else `default_root/0`; `database/0` and
`blobs/0` are `Path.join(root(), …)`. Its module doc argues that the folder is
*fixed* and not chosen — a picker is a path that has to be remembered, in a file
that can be lost — which is a decision to take deliberately, not inherit by
accident.

**(b) The build shape — `mix.exs:70,73`, `config/desktop.exs`.**
`elixirc_paths(:desktop) -> ["lib", "lib_desktop"]` plus `application_module(:desktop)`,
with the extra dependencies under `only: :desktop`, so dev, test and prod never
compile the desktop code. `config/desktop.exs` is read only by `MIX_ENV=desktop`,
and is where `repo_adapter: Ecto.Adapters.SQLite3`, `journal_mode: :wal` and
`pool_size: 1` live — computed from `:filename.basedir(:user_data, …)` so that
`mix ecto.*` also knows where the file is before the application has booted.

**(c) The window — `src-tauri/src/main.rs`.**
Tauri is a window and a process supervisor and nothing else. It starts the
release as a sidecar with `RELEASE_DISTRIBUTION=none` (a fixed node name makes a
second launch die with "seems to be in use by another Erlang node", which the
shell can only report as a sidecar that never said where it listens), reads the
address the release prints on stdout, points a webview at it, and kills the child
on `RunEvent::Exit`. `src-tauri/tauri.bundle.conf.json` puts the release under
`Contents/Resources/rel/<app>`.

**(d) Two things a repository must not contain — `config/desktop.exs`.**
A constant `SECRET_KEY_BASE` is a secret in a repository; the desktop application
generates one per launch instead, because the window is one reader on loopback.
The same reasoning covers the local-admin shortcut: their `:desktop_tool` and
`auto_admin` are what make the loopback reader an administrator, and a release
that mirrors somebody else's site refuses to start with them on.

**(e) The prose precedes the code — `docs/desktop-tool.md`, `docs/desktop-handoff.md`.**
This file follows them.

## What this application has to put in application data

Every path today is either an environment variable or hangs off `$HOME`, which is
the wrong root for an installed application — and is why the image has to fake it
with `HOME=/app/priv`.

- the database file — `ExTbpMonty.Database.sqlite_path/0`
- the artefacts a run leaves beside its record — `Monty.Studio.Artifacts`
- the prerequisite bundles, ~543 MB of YCB objects plus the pretrained memory —
  `Monty.Prerequisites.root_path/1` (`MONTY_DATA` → `~/tbp/data`, `MONTY_MODELS`
  → `~/tbp/results/monty/pretrained_models`, `MONTY_LOGS` →
  `~/tbp/results/monty/projects`)
- the memory export — `:monty_libraries_dir` (`MONTY_LIBRARIES`, else
  `<data>/libraries`), `config/runtime.exs:80`

None of them belongs in the checkout, and all of them should resolve through one
module — call it `Monty.Paths` — which is the piece `Settings` is over there. The
environment variables stay first, so `mix` tasks, CI and the image keep working
unchanged, and the suite is the regression net for that.

## The hard parts, in order of risk

1. **Python and MuJoCo per OS.** The engine is a port to an interpreter
   (`MONTY_PYTHON`, `lib/monty/simulators/port/*`). The image installs
   `libegl1 libgl1 libosmesa6` and sets `MUJOCO_GL` (`Dockerfile:163,173`);
   macOS needs either a bundled interpreter or a GL context it can actually
   open, and Windows is a third story. Decide between bundling a virtual
   environment (largest, most predictable) and requiring an interpreter the user
   installs (smallest, first-run wizard). This, not the window, is the schedule.
2. **Signing and notarisation** on macOS: the sidecar, the NIFs
   (`native/kd_tree_nif`, `native/matcher_nif`) and the hardened runtime all have
   to agree. They already build per platform, so this is bundle-and-sign.
3. **Migrations.** `priv/repo/migrations/20261104090000_wrap_run_json_columns.exs`
   rewrites `log` and `timeline` with `to_jsonb` and is a no-op unless the
   adapter is Postgres. That guard has to survive, and a *fresh* SQLite file gets
   the JSON columns from the create migrations anyway.
4. **The SQLite options are the container's, not a desktop's.** With no
   `journal_mode` set, SQLite uses the rollback journal; the template chooses
   `:wal` and a pool of one. Ours sets `pool_size: 5`. Neither is wrong for one
   user, but the choice should be made rather than inherited.
5. **The secret and the local admin surface** — see (d).

## First steps, small and testable

1. `Monty.Paths`: `default_root/0` = `:filename.basedir(:user_data, "ex-tbp-monty")`,
   and `data/0`, `models/0`, `logs/0`, `libraries/0`, each
   `System.get_env(...) || Path.join(default_root(), …)`.
2. Point `Database.sqlite_path/0`, `Prerequisites.root_path/1` and
   `:monty_libraries_dir` at it.
3. Tests: the default is the OS directory (assert against
   `:filename.basedir(:user_data, …)`, not a literal), and a variable that is set
   still wins.
4. Only then consider `MIX_ENV=desktop`: if the application needs no separate
   supervision tree, it needs no separate environment, and the container and the
   desktop stay one release with different roots. That is the whole point of the
   switch to a file.

## What "done" looks like

`mix release` started with **no environment variables at all**: it boots,
migrates a fresh `ex-tbp-monty.db` under the OS's application-data directory,
answers `/health`, and one tutorial run reaches its conclusion — with nothing
written outside that directory. Then the same binary, with `SQLITE_PATH` and
`MONTY_DATA` set, behaves exactly as it does today.

Half of that is now checked by hand and in CI: a release with only `SQLITE_PATH`
migrates a fresh file and answers `/health` 200 (`3296e41`), and the CI step
that boots the image with no database server runs the same thing in a container.
The other half — the application-data directory as the default root — is what
`Monty.Paths` is for.
