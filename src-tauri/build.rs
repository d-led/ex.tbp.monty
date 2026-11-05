use std::path::Path;

fn main() {
    provenance();

    tauri_build::build()
}

/// The three facts the crash screen names, read from the file the *release*
/// reports in its own footer (`priv/build_info.json`, written by `mix
/// build.info`), so a crash report and the app's own build stamp cannot
/// disagree about which build is at fault.
fn provenance() {
    let file = Path::new("../priv/build_info.json");
    println!("cargo:rerun-if-changed={}", file.display());

    let said = std::fs::read_to_string(file).unwrap_or_default();

    for (key, name) in [
        ("version", "BUILD_VERSION"),
        ("revision", "BUILD_REVISION"),
        ("built_at", "BUILD_BUILT_AT"),
    ] {
        println!("cargo:rustc-env={name}={}", value(&said, key));
    }
}

/// One `"key":"value"` out of the stamp, without a JSON parser: this repository
/// writes the file, it is one flat object, and its strings are quoted. A
/// checkout that was never built has no file, and says `dev` - the same word
/// `ExTbpMonty.BuildInfo` gives a release that was not built by the pipeline.
fn value(json: &str, key: &str) -> String {
    let needle = format!("\"{key}\":\"");

    match json
        .split(&needle)
        .nth(1)
        .and_then(|rest| rest.split('"').next())
    {
        Some(found) if !found.is_empty() => found.to_string(),
        _ => "dev".to_string(),
    }
}
