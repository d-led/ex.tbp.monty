//! The window, and the sidecar behind it.
//!
//! Tauri is a window here, and a process supervisor, and nothing else. It starts
//! the Elixir release, reads the address that release prints, and points a
//! webview at it. Every screen, route and socket belongs to the sidecar — the
//! same binary a headless machine would run — so the window adds no behaviour
//! and cannot drift from the server.

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

/// The release's web-server entry point, in the form `mix release` lays it down
/// on this platform: a shell script on Unix, and `bin\server.bat` on Windows —
/// the same overlay, written twice, because Windows has no shebang.
const SERVER: &str = if cfg!(windows) {
    "bin/server.bat"
} else {
    "bin/server"
};

/// The sidecar, kept so it can be stopped when the window goes away. A window
/// closed over a running server is a port nobody can find again, holding a
/// database open.
struct Sidecar(Mutex<Option<Child>>);

fn main() {
    tauri::Builder::default()
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
        .build(tauri::generate_context!())
        .expect("the window could not be built")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                if let Some(mut child) = app.state::<Sidecar>().0.lock().unwrap().take() {
                    let _ = child.kill();
                    let _ = child.wait();
                }
            }
        });
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
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| format!("{} could not be started: {error}", path.display()))?;

    let stdout = child.stdout.take().ok_or("the sidecar has no output to read")?;
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();

    loop {
        line.clear();

        if reader.read_line(&mut line)? == 0 {
            return Err("the sidecar stopped before it said where it listens".into());
        }

        if let Some(url) = line.trim().strip_prefix("desktop ui: ") {
            let url = url.to_string();

            // Whatever else it prints has to keep being read: a pipe nobody
            // drains fills up and blocks the process writing to it.
            std::thread::spawn(move || {
                for line in reader.lines().map_while(Result::ok) {
                    println!("{line}");
                }
            });

            return Ok((child, url));
        }
    }
}

fn sidecar_path(app: &tauri::App) -> std::path::PathBuf {
    if let Ok(explicit) = std::env::var("EX_TBP_MONTY_SIDECAR") {
        return explicit.into();
    }

    // In a bundle the release travels inside Resources — `bundle.resources` in
    // tauri.bundle.conf.json puts it there — so this is the same layout with a
    // different parent. Asked first, because a window run from the checkout and
    // a window double-clicked from /Applications must not be able to disagree
    // about which release is behind them.
    if let Ok(resources) = app.path().resource_dir() {
        let bundled = resources.join("rel/ex_tbp_monty").join(SERVER);
        if bundled.exists() {
            return bundled;
        }
    }

    // Development: the release inside the checkout.
    Path::new("../_build/desktop/rel/ex_tbp_monty")
        .join(SERVER)
        .to_path_buf()
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
        let mut command = Command::new("cmd");
        command.arg("/C").arg("call").arg(path);
        command
    }

    #[cfg(not(windows))]
    {
        Command::new(path)
    }
}
