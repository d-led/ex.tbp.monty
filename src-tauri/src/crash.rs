//! What the window says when it cannot show the app.
//!
//! Every screen Monty has belongs to the release: the window starts it, reads
//! the address it prints, and points a webview at it. So when the release will
//! not start — or stops — there is nothing to point at, and what a person would
//! otherwise see is the webview's own error page: a blank window with a sentence
//! about a refused connection.
//!
//! This module is the answer to that. A page of this window's own, served from
//! the `splash://` scheme before there is any server: a spinner with three
//! sentences while it starts, and — if it does not come up, or comes up and
//! then dies — a headline that says which situation this is, a sentence about
//! what to do, the build it is (so a report can name it), the release's own
//! last lines folded away, and a link that opens an issue form with all of that
//! already in it.
//!
//! The design is the sibling project's (`confluence_phx_mirror`, `src-tauri/src/
//! main.rs`), and so is the reason for it: every check that asked the *server* a
//! question was green while the window a person opened showed nothing.

use std::collections::VecDeque;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// Where a person reports a failure that is not theirs to fix.
const ISSUES_URL: &str = "https://github.com/d-led/ex.tbp.monty/issues/new";

/// How many of the release's lines travel into a report: enough to hold a
/// refusal and its reason, short enough that the link stays a link.
const REPORTED_LINES: usize = 15;

/// A line of the release's output, kept for the log and behind the page's
/// details. Forty is enough to hold a refusal and its reason.
pub const KEPT_LINES: usize = 40;

/// What went wrong, as far as the window can tell.
///
/// Each variant is a situation a person can act on, and each has its own
/// sentence: two different problems arriving as the same headline is how a
/// report becomes unanswerable.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trouble {
    /// Two copies of the app is two writers to one SQLite file.
    AlreadyRunning,
    /// The release is not where the bundle carries it: a partial download.
    MissingRelease,
    /// The release ran and stopped before it said where it listens.
    Stopped,
    /// The release is still running and has not said, past the deadline.
    Slow,
    /// The release said where it listens and nothing accepts a connection.
    NotAnswering,
    /// The release was serving and then ended, taking every screen with it.
    Died,
}

impl Trouble {
    /// The headline, distinct per situation.
    pub fn title(self) -> &'static str {
        match self {
            Trouble::AlreadyRunning => "Monty on the BEAM is already running",
            Trouble::MissingRelease => "This copy of the app is incomplete",
            Trouble::Stopped => "Monty on the BEAM stopped while starting",
            Trouble::Slow => "Monty on the BEAM is taking longer than it should",
            Trouble::NotAnswering => "The window has nothing to show",
            Trouble::Died => "Monty on the BEAM stopped",
        }
    }

    /// What to do about it, in one breath: no exit codes, no paths a person did
    /// not ask for, no Elixir.
    pub fn explain(self) -> &'static str {
        match self {
            Trouble::AlreadyRunning => {
                "Another copy has this folder open, and two copies would write the \
                 same database. Close its window - the app quits with it - then open \
                 this one again."
            }
            Trouble::MissingRelease => {
                "The program this app runs is missing from it. Download it again; an \
                 interrupted unzip or a partial copy is the usual cause."
            }
            Trouble::Stopped => {
                "It stopped before it was ready. The log below says what it was \
                 doing; nothing in your folder was changed."
            }
            Trouble::Slow => {
                "Starting did not finish within a minute. That is usually a first \
                 launch, a large download to unpack, or a system dialog waiting for \
                 an answer. Quit and open it again."
            }
            Trouble::NotAnswering => {
                "The app started but its server did not answer. Quit and open it \
                 again; if it happens twice, the log below says why."
            }
            Trouble::Died => {
                "Its server ended while the window was open, so the screens went \
                 with it. Nothing in your folder was changed - open the app again. If \
                 it stops a second time, report it below with what it said."
            }
        }
    }

    /// Which situation the release's own output describes.
    ///
    /// Every marker is a sentence this repository prints, so a wrong guess
    /// cannot happen silently: anything unrecognised is [`Trouble::Stopped`],
    /// which is true (it did stop) and says where to look.
    pub fn classify(said: &VecDeque<String>) -> Self {
        let said = said
            .iter()
            .map(|line| line.to_lowercase())
            .collect::<Vec<_>>()
            .join("\n");

        let mentions = |needle: &str| said.contains(needle);

        if mentions("database is locked") || mentions("database busy") {
            Trouble::AlreadyRunning
        } else if mentions("no such file or directory") && mentions("bin/server") {
            Trouble::MissingRelease
        } else {
            Trouble::Stopped
        }
    }
}

/// A failure, ready to be shown: the situation, and the log that explains it.
pub struct Failure {
    pub trouble: Trouble,
    pub log: Option<PathBuf>,
}

/// What the page is drawn from: the trouble, if there is one, and the release's
/// own last lines.
#[derive(Default)]
pub struct Shared {
    pub failed: Option<Failure>,
    pub output: VecDeque<String>,
}

pub type SharedState = Arc<Mutex<Shared>>;

/// The release's output, to the log file and to the page's last lines.
pub struct Sink {
    log: Option<File>,
    shared: SharedState,
}

impl Sink {
    pub fn new(log: Option<&File>, shared: SharedState) -> Self {
        Self {
            log: log.and_then(|file| file.try_clone().ok()),
            shared,
        }
    }

    pub fn line(&mut self, line: &str) {
        if let Some(file) = &mut self.log {
            let _ = writeln!(file, "{line}");
        }

        if let Ok(mut shared) = self.shared.lock() {
            if shared.output.len() == KEPT_LINES {
                shared.output.pop_front();
            }

            shared.output.push_back(line.to_string());
        }
    }
}

/// The page the window is on from the moment it opens: what is happening, or
/// what went wrong.
pub fn startup_page(shared: &Shared) -> String {
    match &shared.failed {
        Some(failure) => failure_page(failure, &shared.output),
        None => waiting_page(),
    }
}

/// Three sentences at three times, each true: that it is starting, that a slow
/// first launch is normal, and that the wait has a bound and the window will
/// explain itself if it cannot start.
pub fn waiting_page() -> String {
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <title>Monty on the BEAM</title>{STYLE}</head>\
         <body><main><div class=\"spinner\"></div>\
         <h1>Starting Monty on the BEAM\u{2026}</h1>\
         <p id=\"hint\">The app is starting its own server.</p></main>\
         <script>(function () {{\
           var hint = document.getElementById('hint');\
           setTimeout(function () {{\
             hint.textContent = 'Still starting. The first launch can take a while.';\
           }}, 5000);\
           setTimeout(function () {{\
             hint.textContent = 'This is taking longer than usual. If it cannot \
             start, this window will say why.';\
           }}, 35000);\
         }})();</script></body></html>"
    )
}

/// What went wrong, in the release's own words.
///
/// The page leads with a sentence and keeps the log one click behind it: the
/// release's lines are the answer for whoever is debugging and noise for
/// whoever is not.
pub fn failure_page(failure: &Failure, output: &VecDeque<String>) -> String {
    let said = output
        .iter()
        .map(|line| escape_html(line))
        .collect::<Vec<_>>()
        .join("\n");

    let details = if said.trim().is_empty() {
        String::new()
    } else {
        format!("<details><summary>What the app said</summary><pre>{said}</pre></details>")
    };

    let log = match &failure.log {
        Some(path) => format!(
            "<p class=\"log\">The app's log has the whole of it: \
             <a href=\"/log\"><code>{}</code></a></p>",
            escape_html(&path.display().to_string())
        ),
        None => String::new(),
    };

    // Every failure offers the issue form, prefilled: the useful report carries
    // what the window already knows, and nobody retypes a log.
    let report = format!(
        "<p class=\"log\">If this is the app's fault rather than something on your \
         side, <a href=\"{}\">open an issue</a> - the page is filled in with the \
         version, your platform and what the app said.</p>",
        escape_html(&issue_url(failure.trouble, output))
    );

    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <title>Monty on the BEAM</title>{STYLE}</head>\
         <body><main><h1>{}</h1>\
         <p class=\"lead\">{}</p>\
         <p class=\"log\">This build: {}</p>\
         <p class=\"log\">Quit the app and open it again once that is dealt with.</p>\
         {report}{details}{log}</main></body></html>",
        escape_html(failure.trouble.title()),
        escape_html(failure.trouble.explain()),
        escape_html(&provenance())
    )
}

/// What build this window is, in one line.
///
/// The three facts come from `priv/build_info.json` through `build.rs`, which is
/// the same file the release reports in its footer - so a crash report and the
/// app's own build stamp cannot disagree about which build is at fault.
pub fn provenance() -> String {
    format!(
        "Monty on the BEAM {} \u{00b7} commit {} \u{00b7} built {}",
        env!("BUILD_VERSION"),
        env!("BUILD_REVISION"),
        env!("BUILD_BUILT_AT")
    )
}

/// The issue form, carrying the window's own account of what happened.
///
/// A bare link asks somebody to describe a failure they cannot name; the form
/// arrives with the headline, the platform, the build and the release's last
/// words already in it, which is what makes a report answerable.
pub fn issue_url(trouble: Trouble, output: &VecDeque<String>) -> String {
    let lines = output
        .iter()
        .rev()
        .take(REPORTED_LINES)
        .rev()
        .cloned()
        .collect::<Vec<_>>()
        .join("\n");

    let body = format!(
        "**What the window said**\n\n{}\n\n**Where**\n\n{} ({})\n\n\
         **App version**\n\n{}\n\n**Last lines from the app**\n\n```\n{lines}\n```\n",
        trouble.title(),
        std::env::consts::OS,
        std::env::consts::ARCH,
        provenance(),
    );

    // GitHub refuses a query past ~8 KB, and a body nothing can receive is no
    // report at all. Counted in characters, so a multi-byte line cannot be cut
    // in half.
    let body = body.chars().take(2_000).collect::<String>();

    format!(
        "{ISSUES_URL}?title={}&body={}",
        url_encoded(&format!("Desktop: {}", trouble.title())),
        url_encoded(&body)
    )
}

/// A query value, encoded: everything a URL cannot carry becomes `%XX`, and the
/// characters that are safe stay readable in the address bar.
pub fn url_encoded(text: &str) -> String {
    let mut encoded = String::with_capacity(text.len());

    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char);
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }

    encoded
}

/// What the title bar says while the page says the rest.
///
/// A webview that will not paint still has a title bar, and it is then the only
/// place left to say that the app has stopped.
pub fn failure_title(trouble: Trouble) -> String {
    format!("Monty on the BEAM - {}", trouble.title())
}

/// Everything a page in this window shows is text from somewhere else, so the
/// one thing it must not do is paste it in as markup.
pub fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The one stylesheet every page in this window uses, including the log page
/// `main.rs` serves: two pages that are one screen should not look like two.
pub const STYLE: &str = "<style>\
  :root { color-scheme: light dark; }\
  body { margin: 0; font: 14px/1.6 -apple-system, system-ui;\
         background: Canvas; color: CanvasText; }\
  main { padding: 40px 44px; max-width: 820px; }\
  h1 { font-size: 19px; margin: 0 0 10px; }\
  .lead { margin: 0 0 4px; }\
  .log { opacity: .65; font-size: 13px; }\
  details { margin: 22px 0 8px; }\
  summary { cursor: pointer; font-size: 13px; opacity: .65; }\
  summary:hover { opacity: .9; }\
  pre { white-space: pre-wrap; word-break: break-word; font: 12px/1.5 ui-monospace, monospace;\
        background: color-mix(in srgb, CanvasText 6%, transparent); padding: 12px;\
        border-radius: 6px; max-height: 260px; overflow: auto; }\
  a { color: LinkText; }\
  .spinner { width: 22px; height: 22px; margin-bottom: 18px; border-radius: 50%;\
             border: 2px solid color-mix(in srgb, CanvasText 22%, transparent);\
             border-top-color: CanvasText; animation: turn .9s linear infinite; }\
  @keyframes turn { to { transform: rotate(360deg); } }\
  @media (prefers-reduced-motion: reduce) { .spinner { animation: none; } }\
</style>";

#[cfg(test)]
mod tests {
    use super::*;

    fn said(lines: &[&str]) -> VecDeque<String> {
        lines.iter().map(|line| line.to_string()).collect()
    }

    /// Two problems arriving as one headline is how a report stops being
    /// answerable: every situation says something of its own, in both voices.
    #[test]
    fn every_situation_says_something_its_own() {
        let all = [
            Trouble::AlreadyRunning,
            Trouble::MissingRelease,
            Trouble::Stopped,
            Trouble::Slow,
            Trouble::NotAnswering,
            Trouble::Died,
        ];

        let titles: std::collections::HashSet<_> =
            all.iter().map(|trouble| trouble.title()).collect();
        let explanations: std::collections::HashSet<_> =
            all.iter().map(|trouble| trouble.explain()).collect();

        assert_eq!(titles.len(), all.len(), "two situations share a headline");
        assert_eq!(
            explanations.len(),
            all.len(),
            "two situations share a sentence"
        );
    }

    /// The markers are sentences this repository prints, so the guess is a
    /// lookup rather than a hunch.
    #[test]
    fn a_locked_database_is_a_second_copy() {
        let output =
            said(&["12:00:00 [error] Exqlite.Error ** (Exqlite.Error) database is locked"]);

        assert_eq!(Trouble::classify(&output), Trouble::AlreadyRunning);
    }

    #[test]
    fn an_unrecognised_failure_is_still_a_failure() {
        assert_eq!(
            Trouble::classify(&said(&["something nobody has seen"])),
            Trouble::Stopped
        );
    }

    /// The page's own copy, so a report reads the same as the window.
    #[test]
    fn the_failure_page_leads_with_the_sentence_and_folds_the_log() {
        let failure = Failure {
            trouble: Trouble::MissingRelease,
            log: None,
        };

        let page = failure_page(&failure, &said(&["bin/server: No such file or directory"]));

        assert!(page.contains("This copy of the app is incomplete"));
        assert!(page.contains("Download it again"));
        assert!(page.contains("<details><summary>What the app said</summary>"));
        assert!(page.contains("bin/server: No such file or directory"));
    }

    #[test]
    fn a_page_with_nothing_said_has_no_empty_fold() {
        let failure = Failure {
            trouble: Trouble::Stopped,
            log: None,
        };

        assert!(!failure_page(&failure, &VecDeque::new()).contains("<details>"));
    }

    /// The log is what a person can send or read past the window, so the page
    /// links to it rather than only printing its path.
    #[test]
    fn the_log_is_a_link_a_person_can_open() {
        let failure = Failure {
            trouble: Trouble::Stopped,
            log: Some(PathBuf::from("/tmp/ex-tbp-monty/window.log")),
        };

        assert!(failure_page(&failure, &VecDeque::new()).contains("<a href=\"/log\">"));
    }

    /// A failure is offered a report the person can send, carrying what the
    /// window already knows.
    #[test]
    fn a_failure_is_offered_a_report_that_carries_the_build() {
        let link = issue_url(Trouble::Died, &said(&["the release stopped"]));

        assert!(link.starts_with(ISSUES_URL));
        assert!(link.contains("title=Desktop%3A%20Monty%20on%20the%20BEAM%20stopped"));
        assert!(link.contains("the%20release%20stopped"));
    }

    #[test]
    fn a_query_value_is_encoded_and_the_readable_parts_are_left_alone() {
        assert_eq!(url_encoded("a b/c-d_e.f~g"), "a%20b%2Fc-d_e.f~g");
    }

    /// A body nothing can receive is no report at all.
    #[test]
    fn a_report_stays_short_enough_to_be_a_link() {
        let long: VecDeque<String> = (0..500).map(|n| format!("line {n} of output")).collect();

        assert!(issue_url(Trouble::Stopped, &long).chars().count() < 8_000);
    }

    #[test]
    fn the_title_bar_says_the_app_stopped_even_if_the_page_cannot_paint() {
        assert_eq!(
            failure_title(Trouble::Died),
            "Monty on the BEAM - Monty on the BEAM stopped"
        );
    }
}
