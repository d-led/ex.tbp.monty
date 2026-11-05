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
use std::sync::{Arc, Mutex};

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

/// Starts the release and blocks until it says where it listens.
fn start_sidecar(app: &tauri::App) -> Result<(Child, String), Box<dyn std::error::Error>> {
    let path = sidecar_path(app);

    let mut child = command(&path)
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

                let mut said = said.lock().unwrap();
                said.push(line);
                if said.len() > 40 {
                    said.remove(0);
                }
            }
        });
    }

    let stdout = child
        .stdout
        .take()
        .ok_or("the sidecar has no output to read")?;
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();

    loop {
        line.clear();

        if reader.read_line(&mut line)? == 0 {
            // What the release said before it went is the whole answer to "why
            // is there no window", and the thread above has been collecting it.
            let said = said.lock().unwrap().join("\n");

            return Err(if said.trim().is_empty() {
                "the sidecar stopped before it said where it listens".to_string()
            } else {
                format!("the sidecar stopped before it said where it listens:\n\n{said}")
            }
            .into());
        }

        if let Some(url) = line.trim().strip_prefix("desktop ui: ") {
            let url = url.to_string();
            log_line(&log_path(), &format!("listening on {url}"));

            // Whatever else it prints has to keep being read: a pipe nobody
            // drains fills up and blocks the process writing to it.
            std::thread::spawn(move || {
                for line in reader.lines().map_while(Result::ok) {
                    let _ = writeln!(std::io::stdout(), "{line}");
                }
            });

            return Ok((child, url));
        }
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

    // Development: the release inside the checkout.
    native(release_at(
        Path::new("..").join("_build").join("desktop").join("rel"),
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
