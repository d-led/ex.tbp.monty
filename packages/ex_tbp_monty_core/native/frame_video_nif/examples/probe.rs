//! The measurement lever: what a run's pictures cost as video, and whether a
//! picture can be read back.
//!
//! ```text
//! cargo run --release --example probe -- /tmp/out.mp4 500 [qp] [gop] [fps]
//! ```
//!
//! Answers the three things a tuning decision needs: the size a frame costs at
//! these settings, how long encoding takes, and how far a decoded frame is from
//! the greys that went in — both through the codec alone and through the video,
//! its index, and a seek from the keyframe.

use std::time::Instant;

use frame_video_nif::video::{frame_at, Kind, Settings, Video};
use rusty_h264::{Decoder, Encoder, EncoderConfig, YuvFrame};

const SIZE: usize = 64;

fn main() {
    let mut arguments = std::env::args().skip(1);
    let path = arguments.next().unwrap_or_else(|| "out.mp4".to_string());
    let frames: usize = arguments
        .next()
        .and_then(|count| count.parse().ok())
        .unwrap_or(500);

    let settings = Settings {
        qp: number(arguments.next(), 18) as u8,
        gop_size: number(arguments.next(), 60),
        fps: number(arguments.next(), 20),
        bitrate: 0,
    };

    let pictures: Vec<Vec<u8>> = (0..frames).map(gradient).collect();

    let decoded = round_trip(&pictures, settings);
    let (written, elapsed) = write_video(&path, &pictures, settings);

    println!("frames: {frames}, settings: {settings:?}");
    println!(
        "video: {written} bytes ({:.1} a frame); index: {} bytes",
        written as f64 / frames as f64,
        index_size(&path)
    );
    println!("as files: {} bytes of APFS blocks", frames * 4096);
    println!(
        "encode: {elapsed:?} ({:.3} ms a frame)",
        elapsed.as_secs_f64() * 1000.0 / frames as f64
    );
    println!("codec decodes: {} frames", decoded.len());

    let last = decoded.len().saturating_sub(1);
    for index in [0, last] {
        println!(
            "codec frame {index}: mean error {:.2} grey levels",
            mean_error(&pictures[index], &decoded[index].y)
        );
    }

    // The path the page takes: a frame number, the index, the keyframe before it.
    for index in [0u64, frames as u64 / 2, last as u64] {
        let started = Instant::now();
        let read = frame_at(std::path::Path::new(&path), index, Kind::Grey);

        match read {
            Ok(frame) => println!(
                "read back frame {index}: mean error {:.2} grey levels, {:?}",
                mean_error(&pictures[index as usize], &frame.pixels),
                started.elapsed()
            ),
            Err(error) => println!("read back frame {index}: {error}"),
        }
    }
}

fn number(given: Option<String>, fallback: u32) -> u32 {
    given.and_then(|value| value.parse().ok()).unwrap_or(fallback)
}

/// The access units decoded back: the codec's own answer, without the container
/// in the way.
fn round_trip(pictures: &[Vec<u8>], settings: Settings) -> Vec<YuvFrame> {
    let mut config = EncoderConfig::baseline(SIZE, SIZE);
    config.qp = settings.qp;
    config.bitrate = settings.bitrate;
    config.gop_size = settings.gop_size;

    let mut encoder = Encoder::new(config).expect("a baseline encoder");
    let mut stream = Vec::new();

    for (index, picture) in pictures.iter().enumerate() {
        if index % settings.gop_size as usize == 0 {
            encoder.request_keyframe();
        }

        stream.extend(encoder.encode(&grey(picture)));
    }

    stream.extend(encoder.flush());

    Decoder::new()
        .decode_stream(&stream)
        .expect("what the encoder wrote, the decoder reads")
}

fn write_video(path: &str, pictures: &[Vec<u8>], settings: Settings) -> (u64, std::time::Duration) {
    let started = Instant::now();

    let mut video = Video::open(
        std::path::Path::new(path),
        SIZE,
        SIZE,
        Kind::Grey,
        settings,
    )
    .expect("a video opens");

    for (index, picture) in pictures.iter().enumerate() {
        let keyframe = index % settings.gop_size as usize == 0;
        video.push(picture, keyframe).expect("a frame encodes");
    }

    video.finish().expect("the video closes");
    let elapsed = started.elapsed();
    let written = std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);

    (written, elapsed)
}

fn index_size(path: &str) -> u64 {
    std::fs::metadata(frame_video_nif::video::index_path(std::path::Path::new(path)))
        .map(|meta| meta.len())
        .unwrap_or(0)
}

/// A grey picture that moves: a flat background and a block that slides, which
/// is what a patch's depth image does between two steps.
fn gradient(index: usize) -> Vec<u8> {
    let mut pixels = vec![0u8; SIZE * SIZE];

    for row in 0..SIZE {
        for column in 0..SIZE {
            let block = (index * 2) % SIZE;
            let inside = column >= block && column < block + 16 && row >= 16 && row < 48;
            pixels[row * SIZE + column] = if inside { 200 } else { 30 + (row as u8) };
        }
    }

    pixels
}

fn grey(picture: &[u8]) -> YuvFrame {
    YuvFrame {
        width: SIZE,
        height: SIZE,
        y: picture.to_vec(),
        u: vec![128; SIZE / 2 * SIZE / 2],
        v: vec![128; SIZE / 2 * SIZE / 2],
    }
}

/// How far the decoded picture is from the greys that went in, in grey levels.
fn mean_error(expected: &[u8], actual: &[u8]) -> f64 {
    let total: u64 = expected
        .iter()
        .zip(actual.iter())
        .map(|(want, got)| want.abs_diff(*got) as u64)
        .sum();

    total as f64 / expected.len() as f64
}
