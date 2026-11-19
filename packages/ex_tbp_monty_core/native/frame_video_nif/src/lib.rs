//! The NIF boundary for `frame_video_nif::video` — a run's pictures as video.
//!
//! Five calls, and the shape is the Elixir side's: `open` hands back a handle,
//! `push` appends one picture, `frames` answers how many are in the file,
//! `finish` ends it, and `frame_at` reads one picture back. The arithmetic is in
//! `video.rs` and `annexb.rs`, which know nothing about the BEAM.
//!
//! Every call that touches the disk is a dirty IO scheduler job. A picture is
//! nowhere near a millisecond to encode at 64 × 64, but a fragment flush is a
//! write, and a write is allowed to block for as long as the filesystem likes.

mod annexb;
pub mod video;

use std::path::Path;
use std::sync::Mutex;

use rustler::{Binary, Env, NewBinary, ResourceArc};

use video::{Kind, Settings, Video};

/// A video being written. The lock is there because a resource is shared with
/// the VM, not because this writer wants concurrency: one process appends a
/// run's pictures, in the order the steps were taken.
struct Writer {
    video: Mutex<Video>,
}

#[rustler::resource_impl]
impl rustler::Resource for Writer {}

/// True from the native side: the only way to know the library loaded.
#[rustler::nif]
fn available() -> bool {
    true
}

/// Opens `path` as a video of `kind` (`"grey"` or `"rgb"`) pictures.
///
/// The settings arrive as one tuple — `{fps, qp, gop_size, bitrate}` — so that
/// what a benchmark sweeps is an argument rather than something compiled in.
#[rustler::nif(schedule = "DirtyIo")]
fn open(
    path: String,
    width: u32,
    height: u32,
    kind: String,
    settings: (u32, u8, u32, u32),
) -> Result<ResourceArc<Writer>, String> {
    let kind = Kind::parse(&kind).ok_or_else(|| format!("a video holds grey or rgb, not {kind}"))?;
    let (fps, qp, gop_size, bitrate) = settings;

    let video = Video::open(
        Path::new(&path),
        width as usize,
        height as usize,
        kind,
        Settings {
            fps,
            qp,
            gop_size,
            bitrate,
        },
    )
    .map_err(|error| error.to_string())?;

    Ok(ResourceArc::new(Writer {
        video: Mutex::new(video),
    }))
}

/// Appends one picture: `width * height` grey bytes, or RGB triples.
#[rustler::nif(schedule = "DirtyIo")]
fn push(writer: ResourceArc<Writer>, pixels: Binary<'_>, keyframe: bool) -> Result<(), String> {
    let mut video = writer
        .video
        .lock()
        .map_err(|_| "the video's lock is poisoned: an earlier frame panicked".to_string())?;

    video
        .push(&pixels, keyframe)
        .map_err(|error| error.to_string())
}

/// How many pictures the file holds: the number a step's picture is named by.
#[rustler::nif]
fn frames(writer: ResourceArc<Writer>) -> u64 {
    match writer.video.lock() {
        Ok(video) => video.frames(),
        Err(_poisoned) => 0,
    }
}

/// Writes what is queued as a fragment: after this, a frame just pushed can be
/// read back.
#[rustler::nif(schedule = "DirtyIo")]
fn flush(writer: ResourceArc<Writer>) -> Result<(), String> {
    let mut video = writer
        .video
        .lock()
        .map_err(|_| "the video's lock is poisoned".to_string())?;

    video.flush().map_err(|error| error.to_string())
}

/// Ends the file, writing what the encoder still holds.
#[rustler::nif(schedule = "DirtyIo")]
fn finish(writer: ResourceArc<Writer>) -> Result<(), String> {
    let mut video = writer
        .video
        .lock()
        .map_err(|_| "the video's lock is poisoned".to_string())?;

    video.finish().map_err(|error| error.to_string())
}

/// How many pictures a video on disk holds: its index, without opening it.
#[rustler::nif(schedule = "DirtyIo")]
fn frames_in(path: String) -> u64 {
    video::frames_in(Path::new(&path))
}

/// One picture of a video on disk, decoded from the keyframe it depends on.
///
/// Answers `{width, height, pixels}` — the picture as the camera drew it, which
/// is what the PNG beside a step used to be.
#[rustler::nif(schedule = "DirtyIo")]
fn frame_at<'a>(
    env: Env<'a>,
    path: String,
    index: u64,
    kind: String,
) -> Result<(u32, u32, Binary<'a>), String> {
    let kind = Kind::parse(&kind).ok_or_else(|| format!("a video holds grey or rgb, not {kind}"))?;

    let decoded =
        video::frame_at(Path::new(&path), index, kind).map_err(|error| error.to_string())?;

    let mut binary = NewBinary::new(env, decoded.pixels.len());
    binary.as_mut_slice().copy_from_slice(&decoded.pixels);

    Ok((decoded.width as u32, decoded.height as u32, binary.into()))
}

rustler::init!("Elixir.ExTbpMonty.Core.FrameVideoNif");
