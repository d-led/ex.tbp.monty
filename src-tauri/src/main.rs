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

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

mod crash;

use crash::{Failure, Shared, SharedState, Sink, Trouble};

/// The scheme the window's own pages are served from: a spinner while the
/// release starts, and the crash screen if it does not - a page that exists
/// before there is any server to point a webview at.
const SPLASH: &str = "splash";

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

    let shared: SharedState = Arc::new(Mutex::new(Shared::default()));

    let built = tauri::Builder::default()
        .manage(Sidecar(Mutex::new(None)))
        // The window's own pages, served before there is a server: what it is
        // doing while it starts, and what went wrong if it does not. Without
        // this the first thing a person sees on a failure is the webview's own
        // error page — a blank window about a refused connection.
        .register_uri_scheme_protocol(SPLASH, {
            let shared = Arc::clone(&shared);

            move |_app, request| {
                let page = if wants_the_log(request.uri().path()) {
                    log_page(shared.lock().unwrap().failed.as_ref())
                } else {
                    crash::startup_page(&shared.lock().unwrap())
                };

                tauri::http::Response::builder()
                    .header("Content-Type", "text/html; charset=utf-8")
                    .body(std::borrow::Cow::Owned(page.into_bytes()))
                    .expect("a page built here is a valid response")
            }
        })
        .setup(move |app| {
            // The window first, and pointed at the waiting page: this used to
            // block until the release had spoken, so a slow boot was a window
            // that did not exist and a failed one was no window at all.
            let window = splash_window(app)?;
            let handle = app.handle().clone();
            let shared = Arc::clone(&shared);

            std::thread::spawn(move || match start_sidecar(&handle, &shared) {
                Ok((child, url)) => {
                    handle.state::<Sidecar>().0.lock().unwrap().replace(child);
                    navigate(&window, &shared, &url);

                    // From here on the server is somebody else's process, and a
                    // window pointed at a server that has ended is a blank tab:
                    // every screen this app has is the server's.
                    watch_sidecar(handle.clone(), window.clone(), Arc::clone(&shared));
                }

                Err(failure) => announce_failure(&window, &shared, failure),
            });

            Ok(())
        })
        .build(tauri::generate_context!());

    let app = match built {
        Ok(app) => app,
        Err(error) => {
            // Before there is a window there is nowhere to draw a page, so this
            // is the one failure a person reads as text: the log, and a box on
            // the platform whose release build has no console.
            let text = format!(
                "The window could not start.\n\n{error}\n\nWritten to {}",
                log.display()
            );
            log_line(&log, &text);
            show_failure(&text);
            std::process::exit(1);
        }
    };

    app.run(|app, event| match event {
        // There is no tray icon and no menu of ours: a window nobody can see is
        // an app nobody can quit, still holding the port and the database the
        // next launch wants.
        tauri::RunEvent::WindowEvent {
            label,
            event: tauri::WindowEvent::Destroyed,
            ..
        } if label == "main" => app.exit(0),

        tauri::RunEvent::Exit => {
            if let Some(mut child) = app.state::<Sidecar>().0.lock().unwrap().take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }

        _ => {}
    });
}

/// The window the app opens with: the waiting page, in the shape this platform
/// can load.
fn splash_window(app: &tauri::App) -> Result<WebviewWindow, Box<dyn std::error::Error>> {
    Ok(
        WebviewWindowBuilder::new(app, "main", WebviewUrl::External(splash_url("").parse()?))
            .title("Monty on the BEAM")
            .inner_size(1280.0, 860.0)
            .min_inner_size(900.0, 600.0)
            .build()?,
    )
}

/// The splash page in the shape the platform can load: a custom scheme where
/// there are custom schemes, and the `*.localhost` form WebView2 needs on
/// Windows.
fn splash_url(suffix: &str) -> String {
    if cfg!(target_os = "windows") {
        format!("http://{SPLASH}.localhost/{suffix}")
    } else {
        format!("{SPLASH}://localhost/{suffix}")
    }
}

/// Points the window at the app - once the address it announced accepts a
/// connection.
///
/// Navigating before that hands the person the webview's own error page: the
/// release says where it listens from inside its listener, so this normally
/// succeeds at once, and the wait is for the microseconds in which it died
/// between the line and the request.
fn navigate(window: &WebviewWindow, shared: &SharedState, url: &str) {
    if answering_within(url, ANSWER_DEADLINE).is_err() {
        announce_failure(
            window,
            shared,
            Failure {
                trouble: Trouble::NotAnswering,
                log: Some(log_path()),
            },
        );
        return;
    }

    let _ = window.navigate(url.parse().expect("the release announced a URL"));
    let _ = window.set_title("Monty on the BEAM");
}

/// Whether the announced address accepts a connection, within `within`.
fn answering_within(url: &str, within: Duration) -> Result<(), ()> {
    let address = url
        .trim_start_matches("http://")
        .split('/')
        .next()
        .unwrap_or_default()
        .to_string();

    let deadline = std::time::Instant::now() + within;

    loop {
        if std::net::TcpStream::connect(&address).is_ok() {
            return Ok(());
        }

        if std::time::Instant::now() > deadline {
            return Err(());
        }

        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Puts a failure in front of the person: the page, and the title bar.
///
/// The title matters because a webview that will not paint - or a window whose
/// page has been replaced by a blank error - still has a title bar, and it is
/// then the only place left to say that the app has stopped.
fn announce_failure(window: &WebviewWindow, shared: &SharedState, failure: Failure) {
    let trouble = failure.trouble;

    // Said in the log too, which is the only witness a headless check has: the
    // page itself is drawn inside a webview, and nothing outside it can read a
    // page that was never given an address.
    log_line(
        &log_path(),
        &format!("showing the crash screen: {}", trouble.title()),
    );

    if let Ok(mut state) = shared.lock() {
        state.failed = Some(failure);
    }

    let _ = window.set_title(&crash::failure_title(trouble));

    // The same page, asked for again: what it serves is read from the state
    // above, so this swap is the whole redraw.
    let _ = window.navigate(splash_url("?failed=1").parse().expect("a splash URL"));
}

/// Watches the sidecar for as long as the window is open.
///
/// A server that ends after it said where it listens is a window showing a
/// browser error nobody can read. The child is polled rather than waited on:
/// `RunEvent::Exit` also holds this handle to kill it, and a thread parked in
/// `wait()` would sit on that lock.
fn watch_sidecar(handle: AppHandle, window: WebviewWindow, shared: SharedState) {
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(1));

        let ended = match handle.state::<Sidecar>().0.lock() {
            Ok(mut sidecar) => match sidecar.as_mut() {
                Some(child) => !matches!(child.try_wait(), Ok(None)),
                None => false,
            },
            Err(_) => false,
        };

        if ended {
            announce_failure(
                &window,
                &shared,
                Failure {
                    trouble: Trouble::Died,
                    log: Some(log_path()),
                },
            );
            return;
        }
    });
}

/// Whether a request for the splash scheme is the crash screen's log link.
fn wants_the_log(path: &str) -> bool {
    path == "/log" || path == "/log/"
}

/// Opens the log in whatever program the person's machine uses for it, and says
/// so on a page: a path printed in a page is a path somebody has to find and
/// copy, and a link is the file itself.
fn log_page(failure: Option<&Failure>) -> String {
    let said = match failure.and_then(|failure| failure.log.as_ref()) {
        None => "There is no log to open - this copy failed before it started one.".to_string(),
        Some(path) => match open_file(path) {
            Ok(()) => format!(
                "Opening {}.",
                crash::escape_html(&path.display().to_string())
            ),
            Err(error) => format!(
                "The log could not be opened ({error}). It is at {}",
                crash::escape_html(&path.display().to_string())
            ),
        },
    };

    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <title>Monty on the BEAM</title>{}</head>\
         <body><main><h1>The log</h1><p class=\"lead\">{said}</p>\
         <p class=\"log\"><a href=\"/?failed=1\">Back to what went wrong</a></p>\
         </main></body></html>",
        crash::STYLE
    )
}

#[cfg(target_os = "macos")]
fn open_file(path: &Path) -> std::io::Result<()> {
    Command::new("open").arg(path).spawn().map(|_| ())
}

#[cfg(target_os = "windows")]
fn open_file(path: &Path) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;

    /// `CREATE_NO_WINDOW`, from `winbase.h`.
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    Command::new("cmd")
        .arg("/C")
        .arg("start")
        .arg("")
        .arg(path)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map(|_| ())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn open_file(path: &Path) -> std::io::Result<()> {
    Command::new("xdg-open").arg(path).spawn().map(|_| ())
}

/// How long the window waits for the release to say where it listens, before it
/// gives up and says what happened. Measured here: a release that has its
/// database already answers in about two seconds, and a first launch pays for the
/// migrations on top of that. A release that will never speak — a missing
/// runtime, a launcher that cannot find its boot file — is indistinguishable from
/// a slow one from the other end of a pipe, and the window is not on screen yet,
/// so the number is what stops a person watching nothing.
const ANNOUNCEMENT_TIMEOUT: Duration = Duration::from_secs(45);

/// How long the announced address gets to accept a connection before the window
/// decides the release is not serving. The release says where it listens from
/// inside its listener, so this normally succeeds at once; the wait is for the
/// case where it died in the microseconds between the line and the request.
const ANSWER_DEADLINE: Duration = Duration::from_secs(10);

/// Starts the release and blocks until it says where it listens.
fn start_sidecar(app: &AppHandle, shared: &SharedState) -> Result<(Child, String), Failure> {
    let log = log_path();
    let path = sidecar_path(app);

    let missing = || Failure {
        trouble: Trouble::MissingRelease,
        log: Some(log.clone()),
    };

    // Named before anything is started: "the program is not there" is a
    // different sentence from "the program would not start", and the difference
    // is the whole of what a person can do about it.
    if !path.exists() {
        log_line(
            &log,
            &format!("no release at {}: this copy is incomplete", path.display()),
        );

        return Err(missing());
    }

    let mut child = match command(&path)
        // The release's own folder, and not whatever directory the window was
        // started from: a double-click, a shortcut, a scheduled task and a
        // `cargo run` each begin somewhere else, and only the release's folder
        // is where its launcher expects to be.
        .current_dir(path.parent().unwrap_or_else(|| Path::new(".")))
        // The application has no peers, so distribution buys it nothing and
        // costs it everything: a release node name is fixed, and a second
        // launch makes this one die with "the name ... seems to be in use by
        // another Erlang node".
        .env("RELEASE_DISTRIBUTION", "none")
        // The pipe is the whole of "my window is alive": the release reads it
        // and stops when it closes, which is the case `RunEvent::Exit` below
        // cannot cover - a window that was force-quit or crashed.
        .env("EX_TBP_MONTY_WINDOW", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        // Drained by a thread from the first moment. An inherited stderr is a
        // console a release build on Windows does not have, and a pipe nobody
        // reads fills up and blocks the process writing to it.
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            log_line(
                &log,
                &format!("{} could not be started: {error}", path.display()),
            );

            // A release that is there and will not run is not a partial copy:
            // the sentence a person can act on is that it did not start.
            return Err(Failure {
                trouble: Trouble::Stopped,
                log: Some(log),
            });
        }
    };

    let opened = open_log(&log);

    if let Some(stderr) = child.stderr.take() {
        let mut sink = Sink::new(opened.as_ref(), Arc::clone(shared));

        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                // `writeln!` and not `println!`: a release build on Windows has
                // no console, and `println!` panics when the write fails - one
                // panic per line, each one showing a failure.
                let _ = writeln!(std::io::stdout(), "{line}");

                sink.line(&line);
            }
        });
    }

    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            let _ = child.kill();
            let _ = child.wait();

            return Err(Failure {
                trouble: Trouble::Stopped,
                log: Some(log),
            });
        }
    };

    let (sender, receiver) = mpsc::channel::<String>();

    // One thread reads the pipe for as long as it is open, so nothing blocks a
    // process that is writing to it, and the announcement can arrive at any time
    // without the window having to sit in `read_line` to see it.
    let keeping = Arc::clone(shared);

    std::thread::spawn(move || {
        let mut sink = Sink::new(None, Arc::clone(&keeping));

        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = writeln!(std::io::stdout(), "{line}");

            sink.line(&line);

            if sender.send(line).is_err() {
                break;
            }
        }
    });

    loop {
        match receiver.recv_timeout(ANNOUNCEMENT_TIMEOUT) {
            Ok(line) => {
                if let Some(url) = line.trim().strip_prefix("desktop ui: ") {
                    let url = url.to_string();
                    log_line(&log, &format!("listening on {url}"));

                    return Ok((child, url));
                }
            }

            // Either it is still thinking or it is gone, and the difference is
            // what the person is told: a release that ended is `Stopped` (and
            // its own last lines usually name why), one that is still running
            // past the deadline is `Slow` - quitting and trying again is what
            // helps there.
            Err(timed_out) => {
                let trouble = match timed_out {
                    mpsc::RecvTimeoutError::Timeout => Trouble::Slow,
                    mpsc::RecvTimeoutError::Disconnected => {
                        Trouble::classify(&shared.lock().unwrap().output)
                    }
                };

                let _ = child.kill();
                let _ = child.wait();

                return Err(Failure {
                    trouble,
                    log: Some(log),
                });
            }
        }
    }
}

/// The release's log, open for appending: the crash screen's link opens this
/// file, so it exists before anything can go wrong.
fn open_log(path: &Path) -> Option<std::fs::File> {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    OpenOptions::new().create(true).append(true).open(path).ok()
}

fn sidecar_path(app: &AppHandle) -> std::path::PathBuf {
    if let Ok(explicit) = std::env::var("EX_TBP_MONTY_SIDECAR") {
        return native(PathBuf::from(explicit));
    }

    let executable = std::env::current_exe().unwrap_or_default();
    let resources = app.path().resource_dir().ok();
    let candidates = release_candidates(resources.as_deref(), &executable);

    match candidates.iter().find(|path| path.exists()) {
        Some(found) => native(found.clone()),
        // Nothing found: hand back the path whose absence is worth naming rather
        // than one the person running the window has to decode.
        None => native(
            candidates
                .into_iter()
                .next()
                .unwrap_or_else(|| release_at(PathBuf::from("rel"))),
        ),
    }
}

/// Where the release may be, in the order to try it.
///
/// The first is the one every shipped shape uses. `bundle.resources` in
/// `tauri.bundle.conf.json` copies the release to `Resources/rel/ex_tbp_monty`
/// inside a `.app`, and `scripts/package.sh` and `scripts/package.ps1` put `rel`
/// beside the window everywhere else - which is the same folder, because
/// `resource_dir()` is the executable's own directory when nothing bundled one.
///
/// It used to look at `Resources/ex_tbp_monty`, one segment short, and then fall
/// back to `../_build/desktop/rel` - relative to the working directory, which for
/// a double-clicked app is `/`. The window died naming a path into somebody's
/// source tree, and `scripts/smoke-window.sh` is what said so.
///
/// The second is development: the release inside the checkout, worked out from
/// this executable and not from the current directory.
fn release_candidates(resources: Option<&Path>, executable: &Path) -> Vec<PathBuf> {
    let bundled = resources.map(|dir| release_at(dir.join("rel")));

    [bundled, checkout_release_of(executable)]
        .into_iter()
        .flatten()
        .collect()
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

    /// Inside a `.app` the release is at `Contents/Resources/rel/ex_tbp_monty`,
    /// because that is what `bundle.resources` copies. Looking one segment
    /// higher found nothing and fell through to a checkout path, and a
    /// double-clicked app died naming somebody's source tree.
    #[test]
    fn the_bundle_is_asked_for_the_release_under_rel() {
        let resources = Path::new("/Applications/Monty on the BEAM.app/Contents/Resources");
        let window =
            Path::new("/Applications/Monty on the BEAM.app/Contents/MacOS/ex-tbp-monty-desktop");

        let candidates = release_candidates(Some(resources), window);

        assert_eq!(
            candidates.first(),
            Some(
                &Path::new("/Applications/Monty on the BEAM.app/Contents/Resources")
                    .join("rel")
                    .join("ex_tbp_monty")
                    .join(SERVER_DIR)
                    .join(SERVER_FILE)
            )
        );
    }

    /// A window is started from wherever the person was — a double-click, a
    /// shortcut, a scheduled task, a `cargo run` — so a release path read from
    /// the working directory is a path that sometimes works.
    #[test]
    fn nothing_the_window_looks_at_is_relative_to_the_working_directory() {
        // The fixture has to be absolute in the platform's own spelling. `\repo`
        // is not absolute on Windows — `Path::is_absolute` wants a drive or a UNC
        // share — so this test failed there saying a release path was read from
        // the working directory when none was.
        #[cfg(windows)]
        let window = Path::new(r"C:\repo\src-tauri\target\debug\ex-tbp-monty-desktop.exe");
        #[cfg(not(windows))]
        let window = Path::new("/repo/src-tauri/target/debug/ex-tbp-monty-desktop");

        for candidate in release_candidates(None, window) {
            assert!(
                candidate.is_absolute(),
                "a release path was read from the working directory: {}",
                candidate.display()
            );
        }
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
