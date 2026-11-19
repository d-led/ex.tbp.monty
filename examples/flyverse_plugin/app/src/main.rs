#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! This example's app shell: the window you double-click, and the node behind it.
//!
//! It lives here, in the example, because the example is what a person takes away
//! — it may depend on a Hex package and on nothing else from the project it was
//! written in. The release beside it is the plugin; this is the shell that finds
//! that release, joins it to a studio window, shows what happened, and stops it
//! when the window closes. The other example carries its own copy: examples here
//! are independent on purpose, and neither one reaches into the other's tree.
//!
//! What it does, in the order it happens: find the release beside itself (`node`
//! names it, `Contents/Resources` on macOS), ask the studio who it is at
//! `/health`, read the studio's `releases/COOKIE`, start the release as
//! `<node>_app@127.0.0.1` with `MONTY_SEEDS`, and stop it with
//! `rpc "System.stop()"` — the same contract the per-platform scripts used to
//! write three times, now once, and with a window that answers Quit (a script is
//! a foreground app to LaunchServices and never answers it, which is why the Dock
//! offered "Force Quit" for an app that was running perfectly).

use std::{
    env, fs,
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::Mutex,
    time::Duration,
};

use serde::Serialize;
use tauri::Manager;

/// How long a window this app opened may take to answer `/health`. A release
/// with an embedded Python and two NIFs takes tens of seconds on a cold start.
const WINDOW_PATIENCE: Duration = Duration::from_secs(120);

/// What this app found around itself, once.
struct Setup {
    /// The app's own name — the executable's file name, which packaging sets from
    /// the app, so Activity Monitor, the Dock and this window agree.
    app_name: String,
    /// The plugin release's name, from the `node` line: `example_plugin`.
    node: String,
    /// The release directory, whose `bin/<node>` starts the node.
    release: PathBuf,
    /// The node this app is in the cluster as: `<node>_app@127.0.0.1`. Not the
    /// release's own name, because `epmd` keys on the bare name and a checkout
    /// runs the same plugin as `example_plugin@127.0.0.1`.
    app_node: String,
    /// The studio window this app joins, when one was found beside it.
    window: Option<PathBuf>,
    /// The studio's release, whose `releases/COOKIE` is what a peer dials with.
    window_release: Option<PathBuf>,
    port: u16,
}

struct AppState {
    setup: Setup,
    cookie: String,
    child: Mutex<Option<Child>>,
    /// A node that was already running when this window opened: not ours to
    /// follow, but ours to report and to stop.
    preexisting: bool,
}

#[derive(Serialize)]
struct Status {
    app_name: String,
    node: String,
    window_node: Option<String>,
    running: bool,
    studio_url: String,
    log: String,
}

#[tauri::command]
fn status(state: tauri::State<'_, AppState>) -> Status {
    let setup = &state.setup;

    Status {
        app_name: setup.app_name.clone(),
        node: setup.app_node.clone(),
        window_node: setup.window.as_ref().and(node_of_window(setup)),
        running: running(state.inner()),
        studio_url: format!("http://127.0.0.1:{}/", setup.port),
        log: log_path(setup).display().to_string(),
    }
}

/// Brings the studio to the front: its page in the default browser, which is the
/// one action that means the same thing on all three platforms.
#[tauri::command]
fn open_studio(state: tauri::State<'_, AppState>) -> Result<(), String> {
    let url = format!("http://127.0.0.1:{}/", state.setup.port);
    open_url(&url).map_err(|error| format!("could not open {url}: {error}"))
}

#[tauri::command]
fn stop_node(state: tauri::State<'_, AppState>) -> Result<(), String> {
    let setup = &state.setup;

    // Asked politely first: a release started with `start` is not a daemon, and
    // `System.stop()` is the same order the studio's own pages use.
    let _ = rpc(setup, &state.cookie, "System.stop()");

    if let Ok(mut child) = state.child.lock() {
        if let Some(mut child) = child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    Ok(())
}

fn running(state: &AppState) -> bool {
    match state.child.lock() {
        Ok(mut child) => match child.as_mut() {
            Some(child) => matches!(child.try_wait(), Ok(None)),
            // Not ours to follow: it was up when this window opened, and this
            // window is the way to stop it. Asking `rpc` here would start a VM
            // every time the page refreshes.
            None => state.preexisting,
        },
        Err(_) => false,
    }
}

fn main() {
    let setup = match discover() {
        Ok(setup) => setup,
        Err(sentence) => fail(&sentence),
    };

    let cookie = cookie(&setup).unwrap_or_default();
    let seed = wait_for_window(&setup);

    let mut state = AppState {
        preexisting: false,
        child: Mutex::new(None),
        setup,
        cookie,
    };

    if let Some(seed) = seed.as_ref() {
        state.preexisting = rpc(&state.setup, &state.cookie, "true");

        if !state.preexisting {
            if let Ok(child) = start_node(&state.setup, &state.cookie, seed) {
                if let Ok(mut slot) = state.child.lock() {
                    *slot = Some(child);
                }
            }
        }
    }

    let title = format!("{} — a Monty plugin node", state.setup.app_name);
    let app = tauri::Builder::default()
        .manage(state)
        .invoke_handler(tauri::generate_handler![status, open_studio, stop_node])
        .setup(move |app| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_title(&title);
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .unwrap_or_else(|error| fail(&format!("the window could not be built: {error}")));

    // Closing the window is stopping the node: these two are one app, and a node
    // left behind would hold its name, and the next click would say the node is
    // running when nothing can be seen.
    app.run(|app, event| {
        if let tauri::RunEvent::Exit = event {
            let state = app.state::<AppState>();
            let _ = stop_node(state);
        }
    });
}

/// A sentence where a window cannot be shown, on whatever the platform gives.
fn fail(sentence: &str) -> ! {
    eprintln!("{sentence}");
    #[cfg(target_os = "macos")]
    let _ = Command::new("osascript")
        .arg("-e")
        .arg(format!(
            "display alert \"Monty plugin node\" message \"{}\" as warning",
            sentence.replace('"', "'")
        ))
        .status();
    std::process::exit(1)
}

// ---------------------------------------------------------------------------
// What is around this binary
// ---------------------------------------------------------------------------

fn discover() -> Result<Setup, String> {
    let exe = env::current_exe().map_err(|error| format!("where am I: {error}"))?;
    let dir = exe
        .parent()
        .ok_or_else(|| "the executable has no folder".to_string())?
        .to_path_buf();

    let app_name = exe
        .file_stem()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "Monty plugin node".to_string());

    // A macOS bundle keeps the launcher in `Contents/MacOS` and everything else
    // in `Contents/Resources`; the other two platforms keep all three things in
    // one folder, which is why the first location is tried first and the second
    // is the fallback.
    let resources = dir.join("../Resources");
    let (node, release) = match read_node(resources.as_path()) {
        Some(node) => {
            let release = resources.join(&node);
            (node, release)
        }
        None => {
            let node = read_node(&dir).ok_or_else(|| {
                format!(
                    "{} is not a plugin app: no `node` beside the executable or in ../Resources",
                    dir.display()
                )
            })?;
            let release = dir.join(&node);
            (node, release)
        }
    };

    if !release.join("bin").exists() {
        return Err(format!(
            "this app carries no {node} release: {} has no bin/",
            release.display()
        ));
    }

    let (window, window_release) = window_beside(&dir);

    Ok(Setup {
        app_name: app_name.clone(),
        app_node: format!("{node}_app@127.0.0.1"),
        node,
        release,
        window,
        window_release,
        port: preferred_port(),
    })
}

fn read_node(folder: &Path) -> Option<String> {
    let text = fs::read_to_string(folder.join("node")).ok()?;
    let name = text.trim();

    (!name.is_empty()).then(|| name.to_string())
}

/// The studio this app joins: named, or beside the app, and nowhere else.
///
/// A companion that searched the disk would join whichever window it found
/// first, and which one that is would be nobody's decision.
fn window_beside(dir: &Path) -> (Option<PathBuf>, Option<PathBuf>) {
    if let Some(named) = env::var_os("MONTY_STUDIO_APP") {
        let named = PathBuf::from(named);
        let release = release_of_window(&named);
        return (Some(named), release);
    }

    #[cfg(target_os = "macos")]
    {
        // <folder>/<Name>.app/Contents/MacOS → <folder>/Monty on the BEAM.app
        let app = dir.join("../../../Monty on the BEAM.app");
        if app.exists() {
            let release = app.join("Contents/Resources/rel/ex_tbp_monty");
            return (Some(app), Some(release).filter(|path| path.exists()));
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let mut candidates = vec![
            dir.join("ex-tbp-monty-desktop"),
            dir.join("ex-tbp-monty-desktop.exe"),
        ];
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path
                    .extension()
                    .is_some_and(|extension| extension == "AppImage")
                {
                    candidates.push(path);
                }
            }
        }
        if let Some(window) = candidates.into_iter().find(|candidate| candidate.exists()) {
            let release = dir.join("rel/ex_tbp_monty");
            return (Some(window), Some(release).filter(|path| path.exists()));
        }
    }

    (None, None)
}

fn release_of_window(window: &Path) -> Option<PathBuf> {
    if window.is_dir() {
        let inside = window.join("Contents/Resources/rel/ex_tbp_monty");
        return Some(inside).filter(|path| path.exists());
    }

    let beside = window
        .parent()
        .map(|folder| folder.join("rel/ex_tbp_monty"))
        .unwrap_or_default();

    Some(beside).filter(|path| path.exists())
}

/// The port the studio prefers, read the way the studio reads it: the
/// environment, then the settings file a person can edit, then 42 800.
fn preferred_port() -> u16 {
    named_port().or_else(settings_port).unwrap_or(42_800)
}

fn named_port() -> Option<u16> {
    env::var("MONTY_DESKTOP_PORT")
        .ok()
        .and_then(|port| port.trim().parse().ok())
}

fn settings_port() -> Option<u16> {
    let settings = {
        #[cfg(target_os = "macos")]
        {
            env::var_os("HOME").map(|home| {
                PathBuf::from(home).join("Library/Application Support/ex-tbp-monty/desktop_port")
            })
        }

        #[cfg(target_os = "linux")]
        {
            env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
                .map(|folder| folder.join("ex-tbp-monty/desktop_port"))
        }

        #[cfg(target_os = "windows")]
        {
            env::var_os("APPDATA")
                .map(|folder| PathBuf::from(folder).join("ex-tbp-monty/desktop_port"))
        }
    }?;

    fs::read_to_string(settings)
        .ok()
        .and_then(|port| port.trim().parse().ok())
}

// ---------------------------------------------------------------------------
// The studio, and the node
// ---------------------------------------------------------------------------

/// The studio's node name, once it answers — opening the studio first when
/// nothing answers, because a companion is one double-click away from having one.
fn wait_for_window(setup: &Setup) -> Option<String> {
    let mut opened = false;
    let deadline = std::time::Instant::now() + WINDOW_PATIENCE;

    loop {
        if let Some(node) = node_of_window(setup) {
            return Some(node);
        }

        if !opened {
            if let Some(window) = setup.window.as_ref() {
                let _ = open_app(window);
                opened = true;
            } else {
                return None;
            }
        }

        if std::time::Instant::now() > deadline {
            return None;
        }

        std::thread::sleep(Duration::from_secs(1));
    }
}

fn node_of_window(setup: &Setup) -> Option<String> {
    let body = http_body(setup.port, "/health")?;
    let key = "\"node\":\"";
    let start = body.find(key)? + key.len();
    let rest = &body[start..];
    let end = rest.find('"')?;

    Some(rest[..end].to_string())
}

fn cookie(setup: &Setup) -> Option<String> {
    for name in ["MONTY_CLUSTER_SECRET", "MONTY_COOKIE"] {
        if let Ok(value) = env::var(name) {
            if !value.is_empty() {
                return Some(value);
            }
        }
    }

    let release = setup.window_release.as_ref()?;
    let text = fs::read_to_string(release.join("releases/COOKIE")).ok()?;
    let cookie = text.trim();

    (!cookie.is_empty()).then(|| cookie.to_string())
}

fn start_node(setup: &Setup, cookie: &str, seed: &str) -> std::io::Result<Child> {
    // The node's own log, in the folder the old launchers used, appended and
    // never truncated: a node that refuses to start says why there, and a second
    // click must not delete the log the running node is writing.
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path(setup))?;

    let mut command = release_command(setup, cookie);
    command
        .arg("start")
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log))
        .env("MONTY_SEEDS", seed)
        .spawn()
}

fn log_path(setup: &Setup) -> PathBuf {
    env::temp_dir().join(format!("monty-studio-{}.log", setup.node))
}

/// A node that answers `true` to `rpc` is running; one that does not is not. It
/// is the same question the old launchers asked, and the only one a release
/// answers without a pid file.
fn rpc(setup: &Setup, cookie: &str, expression: &str) -> bool {
    let mut command = release_command(setup, cookie);
    command.arg("rpc").arg(expression);
    command
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

/// The release's own launcher, with every `RELEASE_*` this process happens to
/// carry removed: a launcher defaults a variable only while it is unset or
/// empty, and an inherited version number sends the child looking for a release
/// folder that does not exist.
fn release_command(setup: &Setup, cookie: &str) -> Command {
    let inherited: Vec<String> = env::vars()
        .map(|(name, _)| name)
        .filter(|name| name.starts_with("RELEASE_"))
        .collect();

    let mut command = Command::new(launcher(&setup.release, &setup.node));
    command
        .current_dir(&setup.release)
        .env("RELEASE_DISTRIBUTION", "name")
        .env("RELEASE_NODE", &setup.app_node);

    for name in inherited {
        command.env_remove(name);
    }

    command.env("RELEASE_COOKIE", cookie);
    command
}

fn launcher(release: &Path, node: &str) -> PathBuf {
    let bin = release.join("bin").join(node);

    #[cfg(target_os = "windows")]
    {
        bin.with_extension("bat")
    }

    #[cfg(not(target_os = "windows"))]
    {
        bin
    }
}

// ---------------------------------------------------------------------------
// The three platform verbs
// ---------------------------------------------------------------------------

fn open_app(path: &Path) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        Command::new("open").arg(path).status().map(|_| ())
    }

    #[cfg(not(target_os = "macos"))]
    {
        // Detached on purpose: the studio has to outlive this launcher.
        Command::new(path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map(|_| ())
    }
}

fn open_url(url: &str) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = Command::new("open");
        command.arg(url);
        command
    };

    #[cfg(target_os = "linux")]
    let mut command = {
        let mut command = Command::new("xdg-open");
        command.arg(url);
        command
    };

    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("cmd");
        command.args(["/C", "start", "", url]);
        command
    };

    command
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|_| ())
}

/// A health probe with nothing behind it: one GET on the loopback and the body.
/// A whole HTTP client would be a dependency for one request that cannot fail in
/// any way this window has to understand.
fn http_body(port: u16, path: &str) -> Option<String> {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(2)).ok()?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .ok()?;

    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
    )
    .ok()?;

    let mut response = String::new();
    stream.read_to_string(&mut response).ok()?;

    response
        .split_once("\r\n\r\n")
        .map(|(_head, body)| body.to_string())
}
