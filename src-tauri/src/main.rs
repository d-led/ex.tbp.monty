//! The window, and the sidecar behind it.
//!
//! Tauri is a window here, and a process supervisor, and nothing else. It starts
//! the Elixir release, reads the address that release prints, and points a
//! webview at it. Every screen, route and socket belongs to the sidecar — the
//! same binary a headless machine would run — so the window adds no behaviour
//! and cannot drift from the server.

// A release build on Windows is a window, not a console program. Without this,
// every launch opens a console of its own — and a startup failure closes it
// again before the sentence on it can be read, which is what "a console window
// that flashes and disappears" is. What a failure says goes to the log below.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

/// The release's web-server entry point, in the form `mix release` lays it down
/// on this platform: a shell script on Unix, and `bin\server.bat` on Windows —
/// the same overlay, written twice, because Windows has no shebang.
///
/// Directory and file as two names, joined one at a time. `join("bin/server.bat")`
/// keeps the forward slash *inside* the path, and Windows accepts such a path in
/// `cmd` — but `%~dp0` inside the batch file then carries that slash too, so the
/// release's own launcher builds `…\bin/..\releases\0.1.0\start` and `erl` answers
/// **"cannot get boot file"**. That is how this window failed the first time it
/// was started on Windows.
const SERVER_DIR: &str = "bin";
const SERVER_FILE: &str = if cfg!(windows) {
    "server.bat"
} else {
    "server"
};

/// The sidecar, kept so it can be stopped when the window goes away. A window
/// closed over a running server is a port nobody can find again, holding a
/// database open.
struct Sidecar(Mutex<Option<Child>>);

fn main() {
    let log = log_path();
    install_panic_log(&log);

    if let Err(error) = run() {
        // A window that dies here would otherwise leave nothing behind: the
        // release build has no console, so stderr goes nowhere and the process
        // is gone before anyone can read a sentence about why.
        let text = format!(
            "The window could not start.\n\n{error}\n\nWritten to {}",
            log.display()
        );
        log_line(&log, &text);
        show_failure(&text);
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let app = tauri::Builder::default()
        .manage(Sidecar(Mutex::new(None)))
        .setup(|app| {
            let (child, url) = start_sidecar(app)?;
            app.state::<Sidecar>().0.lock().unwrap().replace(child);

            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url.parse()?))
                .title("Monty on the BEAM")
                .inner_size(1280.0, 860.0)
                .min_inner_size(900.0, 600.0)
                .build()?;

            Ok(())
        })
        .build(tauri::generate_context!())?;

    app.run(|app, event| {
        if let tauri::RunEvent::Exit = event {
            if let Some(mut child) = app.state::<Sidecar>().0.lock().unwrap().take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    });

    Ok(())
}

/// How long the window waits for the release to say where it listens, before it
/// gives up and says what happened. Measured here: a release that has its
/// database already answers in about two seconds, and a first launch pays for the
/// migrations on top of that. A release that will never speak — a missing
/// runtime, a launcher that cannot find its boot file — is indistinguishable from
/// a slow one from the other end of a pipe, and the window is not on screen yet,
/// so the number is what stops a person watching nothing.
const ANNOUNCEMENT_TIMEOUT: Duration = Duration::from_secs(45);

/// Starts the release and blocks until it says where it listens.
fn start_sidecar(app: &tauri::App) -> Result<(Child, String), Box<dyn std::error::Error>> {
    let path = sidecar_path(app);

    let mut child = command(&path)
        // The release's own folder, and not whatever directory the window was
        // started from: a double-click, a shortcut, a scheduled task and a
        // `cargo run` each begin somewhere else, and only the release's folder is
        // where its launcher expects to be.
        .current_dir(path.parent().unwrap_or_else(|| Path::new(".")))
        // `bin/server` is the release's own web-server entry point: it runs the
        // migrations this application keeps in two directories and then starts
        // the endpoint, in that order, in one VM.
        // The application has no peers, so distribution buys it nothing and
        // costs it everything: a release node name is fixed, and a second
        // launch — or a sidecar left running by an earlier one — makes this one
        // die with "the name … seems to be in use by another Erlang node",
        // which the shell can only report as a sidecar that never said where it
        // listens.
        .env("RELEASE_DISTRIBUTION", "none")
        // The pipe is the whole of "my window is alive": the release reads it
        // and stops when it closes, which is the case `RunEvent::Exit` below
        // cannot cover — a window that was force-quit or crashed.
        .env("EX_TBP_MONTY_WINDOW", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        // Drained by a thread from the first moment. An inherited stderr is a
        // console a release build on Windows does not have, and a pipe nobody
        // reads fills up and blocks the process writing to it.
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("{} could not be started: {error}", path.display()))?;

    let said = Arc::new(Mutex::new(Vec::new()));

    if let Some(stderr) = child.stderr.take() {
        let said = Arc::clone(&said);
        let log = log_path();

        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                log_line(&log, &line);
                // `writeln!` and not `println!`: a release build on Windows has
                // no console, and `println!` panics when the write fails — one
                // panic per line, each one showing the failure box.
                let _ = writeln!(std::io::stdout(), "{line}");

                remember(&said, line);
            }
        });
    }

    let stdout = child
        .stdout
        .take()
        .ok_or("the sidecar has no output to read")?;
    let (sender, receiver) = mpsc::channel::<String>();

    // One thread reads the pipe for as long as it is open, so nothing blocks a
    // process that is writing to it, and the announcement can arrive at any time
    // without the window having to sit in `read_line` to see it.
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = writeln!(std::io::stdout(), "{line}");

            if sender.send(line).is_err() {
                break;
            }
        }
    });

    loop {
        match receiver.recv_timeout(ANNOUNCEMENT_TIMEOUT) {
            Ok(line) => match line.trim().strip_prefix("desktop ui: ") {
                Some(url) => {
                    let url = url.to_string();
                    log_line(&log_path(), &format!("listening on {url}"));

                    return Ok((child, url));
                }
                None => remember(&said, line),
            },

            // The release is gone, or it is still thinking. Either way there is no
            // window to show and no point in the caller waiting for one: say what
            // it said, stop it, and let `main` put that in front of a person.
            Err(timed_out) => {
                let what = match timed_out {
                    mpsc::RecvTimeoutError::Timeout => format!(
                        "the release did not say where it listens within {} seconds",
                        ANNOUNCEMENT_TIMEOUT.as_secs()
                    ),
                    mpsc::RecvTimeoutError::Disconnected => {
                        "the release stopped before it said where it listens".to_string()
                    }
                };

                let _ = child.kill();
                let _ = child.wait();

                let tail = said.lock().unwrap().join("\n");

                return Err(if tail.trim().is_empty() {
                    format!("{what}, and said nothing")
                } else {
                    format!("{what}. What it said:\n\n{tail}")
                }
                .into());
            }
        }
    }
}

/// The last lines a process printed, kept for the moment something has to say why
/// it went quiet. Bounded, because a sidecar that runs for hours prints forever.
fn remember(said: &Arc<Mutex<Vec<String>>>, line: String) {
    let mut said = said.lock().unwrap();
    said.push(line);

    if said.len() > 40 {
        said.remove(0);
    }
}

fn sidecar_path(app: &tauri::App) -> std::path::PathBuf {
    if let Ok(explicit) = std::env::var("EX_TBP_MONTY_SIDECAR") {
        return native(PathBuf::from(explicit));
    }

    // In a bundle the release travels inside Resources — `bundle.resources` in
    // tauri.bundle.conf.json puts it there — so this is the same layout with a
    // different parent. Asked first, because a window run from the checkout and
    // a window double-clicked from /Applications must not be able to disagree
    // about which release is behind them.
    if let Ok(resources) = app.path().resource_dir() {
        let bundled = release_at(resources);
        if bundled.exists() {
            return native(bundled);
        }
    }

    // Development: the release inside the checkout, worked out from this
    // executable and not from the current directory. A debug window can be
    // started from anywhere, and `target/debug/…` is four levels below the
    // repository wherever that was.
    let checkout = checkout_release_of(&std::env::current_exe().unwrap_or_default())
        .unwrap_or_else(|| release_at(Path::new("..").join("_build").join("desktop").join("rel")));

    // Nothing found anywhere: hand back the path whose absence the error names.
    native(checkout)
}

/// `…/src-tauri/target/debug/ex-tbp-monty-desktop` → the release that checkout
/// builds, `…/_build/desktop/rel/ex_tbp_monty/bin/server`.
fn checkout_release_of(window_executable: &Path) -> Option<PathBuf> {
    let repository = window_executable.ancestors().nth(4)?;

    Some(release_at(
        repository.join("_build").join("desktop").join("rel"),
    ))
}

fn release_at(parent: PathBuf) -> PathBuf {
    parent
        .join("ex_tbp_monty")
        .join(SERVER_DIR)
        .join(SERVER_FILE)
}

/// Every separator the same on Windows, because the release's batch launchers
/// pass their own directory on to `erl` and `erl` does not normalise `…\bin/..`
/// into `…`. On Unix a path is already a path.
#[cfg(windows)]
fn native(path: PathBuf) -> PathBuf {
    PathBuf::from(path.to_string_lossy().replace('/', "\\"))
}

#[cfg(not(windows))]
fn native(path: PathBuf) -> PathBuf {
    path
}

/// The command that runs the entry point.
///
/// On Unix it is the script itself. On Windows it is a `.bat`, which is not a
/// program: it is text that `cmd.exe` reads, so `Command::new` on it fails with
/// "not a valid Win32 application". The `call` is not decoration either — a
/// quoted path with a space in it (`…\Monty on the BEAM\…`) is what the bundle
/// hands over, and `cmd` alone splits it at the first space.
fn command(path: &Path) -> Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;

        // `CREATE_NO_WINDOW`, or the child gets a console window of its own: the
        // window process is now a GUI-subsystem program, and anything it spawns
        // from a console program's family tree is given a console. That black
        // flash was this as much as it was the window's own subsystem. The
        // sidecar has no use for a console — what it says is read from the pipe
        // and written to the log.
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;

        let mut command = Command::new("cmd");
        command
            .arg("/C")
            .arg("call")
            .arg(path)
            .creation_flags(CREATE_NO_WINDOW);
        command
    }

    #[cfg(not(windows))]
    {
        Command::new(path)
    }
}

/// Where a failure is written — the folder the application keeps its own files
/// in, which is what `Monty.Paths.root/0` answers without an Elixir running:
/// `%APPDATA%\ex-tbp-monty` on Windows, `~/Library/Application Support/…` on
/// macOS, `$XDG_DATA_HOME` or `~/.local/share` on Linux.
///
/// One body for every platform, chosen at run time: a `cfg` here would leave the
/// two branches this build never compiles unseen until a bundled release runs
/// them.
fn log_path() -> PathBuf {
    let base = match std::env::consts::OS {
        "windows" => std::env::var_os("APPDATA").map(PathBuf::from),
        "macos" => std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join("Library/Application Support")),
        _ => std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"))
            }),
    };

    base.unwrap_or_else(std::env::temp_dir)
        .join("ex-tbp-monty")
        .join("window.log")
}

fn log_line(path: &Path, line: &str) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{line}");
    }
}

/// A panic is a failure like any other here, and a release build has no console
/// to print it to.
fn install_panic_log(path: &Path) {
    let previous = std::panic::take_hook();
    let path = path.to_path_buf();

    std::panic::set_hook(Box::new(move |info| {
        log_line(&path, &format!("the window stopped: {info}"));
        previous(info);
    }));
}

/// Says what went wrong where a person will be looking: a terminal on the
/// platforms whose build keeps one, and a message box on Windows, whose release
/// build does not.
#[cfg(all(windows, not(debug_assertions)))]
fn show_failure(message: &str) {
    // The text travels in an environment variable rather than inside the command:
    // a path with a quote in it, or a sentence with an apostrophe, would
    // otherwise have to be escaped once for PowerShell and again for the box.
    let _ = Command::new("powershell")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            "Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show(\
             $env:EX_TBP_MONTY_COMPLAINT, 'Monty on the BEAM') | Out-Null",
        ])
        .env("EX_TBP_MONTY_COMPLAINT", message)
        .status();
}

#[cfg(not(all(windows, not(debug_assertions))))]
fn show_failure(message: &str) {
    let _ = writeln!(std::io::stderr(), "{message}");
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The entry point is joined one component at a time. Written as one string —
    /// `join("bin/server.bat")` — Windows keeps the forward slash, `cmd` hands it
    /// on through `%~dp0`, and the release's own launcher then builds
    /// `…\bin/..\releases\0.1.0\start` and `erl` answers "cannot get boot file".
    #[test]
    fn the_entry_point_is_joined_from_components() {
        let joined = release_at(PathBuf::from("root"));

        assert_eq!(
            joined,
            Path::new("root")
                .join("ex_tbp_monty")
                .join(SERVER_DIR)
                .join(SERVER_FILE)
        );
    }

    /// Whatever the bundle hands over, the launcher gets separators this platform
    /// reads. On Windows that means no `/` at all; elsewhere the path is already
    /// right and is left alone.
    #[test]
    fn the_launcher_gets_this_platforms_separators() {
        let mixed = native(PathBuf::from("root/rel/ex_tbp_monty/bin/server.bat"));
        let text = mixed.to_string_lossy().into_owned();

        if cfg!(windows) {
            assert!(
                !text.contains('/'),
                "a forward slash reached the launcher: {text}"
            );
        } else {
            assert!(
                text.contains('/'),
                "the path was rewritten on a platform that did not need it: {text}"
            );
        }
    }

    /// A debug window can be started from any directory, so the release it is
    /// meant to run is found from the executable — four levels below the
    /// repository — and never from where the process happens to stand.
    #[test]
    fn the_checkout_release_is_found_from_the_executable() {
        let window = Path::new("/repo/src-tauri/target/debug/ex-tbp-monty-desktop");
        let expected = Path::new("/repo")
            .join("_build")
            .join("desktop")
            .join("rel")
            .join("ex_tbp_monty")
            .join(SERVER_DIR)
            .join(SERVER_FILE);

        assert_eq!(checkout_release_of(window), Some(expected));
    }

    /// A release that never speaks is not a release that speaks slowly: the wait
    /// is bounded, so a person is told within a stated number of seconds instead
    /// of watching nothing happen.
    #[test]
    fn the_wait_for_the_release_is_bounded() {
        assert_eq!(ANNOUNCEMENT_TIMEOUT.as_secs(), 45);
    }

    /// A window that fails has nowhere to print: a release build on Windows has no
    /// console, and a macOS `.app` opened from the Finder has no terminal. The file
    /// is the trace, and it goes where the application keeps the rest of its files.
    #[test]
    fn a_failure_is_written_beside_the_applications_own_files() {
        let path = log_path();

        assert!(
            path.ends_with(Path::new("ex-tbp-monty").join("window.log")),
            "the log landed outside the application's folder: {}",
            path.display()
        );
    }
}
