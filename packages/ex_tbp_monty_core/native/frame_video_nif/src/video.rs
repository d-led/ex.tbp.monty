//! One video of a run's pictures, instead of a file per picture.
//!
//! A studio run used to write four PNGs a step — `<step>/<sensor>-<kind>.png` —
//! and a run of 53 826 steps left **215 304 files taking 882 MB of disk for 48.7
//! MB of pixels**, because a 100-byte picture still occupies a whole block and
//! every picture costs an inode, a directory entry and a metadata write. This is
//! the other shape: one H.264 video per sensor and kind, appended as the run
//! steps, so a run leaves a handful of files that the filesystem is built to hold.
//!
//! ## Why fragmented, and why intra frames at known places
//! A plain MP4 writes its index (`moov`) at the end, so a run killed halfway —
//! which this application's own runs are, often — would leave a file no player
//! opens. Fragmented MP4 writes `ftyp`+`moov`+`mvex` first and then a
//! self-contained `moof`+`mdat` per fragment: everything already flushed stays
//! playable and seekable, whatever happens next.
//!
//! A fragment can only start on a keyframe, and a seek can only start from one,
//! so the caller says when a frame is a keyframe (`push`, `keyframe`) and the
//! fragment is flushed there. The writer keys an episode's first frame, which is
//! a real discontinuity — and, as a ceiling, every `gop` frames.
//!
//! ## The index, and why there is a second small file
//! Reading one picture back — which is what the page asks for when a replay
//! shows a step — means starting at the last keyframe and decoding forward.
//! Fragment headers carry that information, but only in a form a demuxer has to
//! reconstruct; the sample offsets are cheap to record *while* writing. So next
//! to the video is `<video>.index`, nine bytes a frame: where the sample's bytes
//! start, how long they are, and whether it is a keyframe. It is written after
//! the fragment it describes, so a truncated video can never be described by an
//! index that promises bytes the file does not hold.
//!
//! ## Colour, and the two things this cannot promise
//! H.264 in this profile is 4:2:0 and lossy: chroma is stored at half resolution
//! and the luma is quantised. A depth picture is one channel, so it travels as
//! luma with neutral chroma and is as exact as the quantiser allows; a colour
//! picture loses half its chroma resolution. These are pictures for a person to
//! look at — the numbers a run is judged by are in its record, not in its
//! pictures — and the quantiser is deliberately low (`QP` 18) because at 64 × 64
//! the difference between 18 and 26 is a few bytes and the difference between
//! them is visible.

use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use muxide::fragmented::{FragmentConfig, FragmentedMuxer};
use rusty_h264::{Decoder, Encoder, EncoderConfig, YuvFrame};

use crate::annexb::{
    contains_idr, from_length_prefixed, grey_frame, nal_of_type, rgb_frame, to_length_prefixed,
};

/// What a picture is: one value a pixel (a depth image), or three.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Grey,
    Rgb,
}

impl Kind {
    /// Bytes one pixel of this kind takes in the caller's binary.
    pub fn channels(self) -> usize {
        match self {
            Kind::Grey => 1,
            Kind::Rgb => 3,
        }
    }

    /// The word the Elixir side names a kind by.
    pub fn parse(kind: &str) -> Option<Self> {
        match kind {
            "grey" => Some(Kind::Grey),
            "rgb" => Some(Kind::Rgb),
            _other => None,
        }
    }
}

/// How a video is encoded: the knobs a benchmark sweeps and a caller tunes.
///
/// Nothing here is a constant of the codec: the quantiser decides how much of a
/// grey survives, the gop is how far a seek may have to decode, and the frame
/// rate is the mapping between a step's number and the second a player seeks to.
/// The defaults are what the studio wants; a caller that knows better passes its
/// own.
#[derive(Debug, Clone, Copy)]
pub struct Settings {
    /// Ticks a second, and frames a second: one tick a frame.
    pub fps: u32,
    /// Quantiser from 0 (near-lossless, larger) to 51 (small, visible).
    pub qp: u8,
    /// The longest a seek may have to decode: a keyframe at least this often.
    pub gop_size: u32,
    /// Bits a second, or 0 for the constant quantiser above.
    pub bitrate: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            fps: 20,
            qp: 18,
            gop_size: 60,
            bitrate: 0,
        }
    }
}

impl Settings {
    /// The frame rate as a timescale, never zero — a muxer cannot divide by it.
    fn timescale(self) -> u32 {
        self.fps.max(1)
    }
}

/// What went wrong, in the words the Elixir side puts in a warning.
#[derive(Debug)]
pub enum Error {
    /// The caller's binary is not `width * height * channels` bytes.
    FrameSize { expected: usize, got: usize },
    Encode(String),
    Mux(String),
    Io(String),
    /// A frame number the video does not hold, or a video with no index.
    NoSuchFrame(u64),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::FrameSize { expected, got } => {
                write!(f, "a frame of {expected} bytes, not {got}")
            }
            Error::Encode(reason) => write!(f, "the encoder refused a frame: {reason}"),
            Error::Mux(reason) => write!(f, "the muxer refused a frame: {reason}"),
            Error::Io(reason) => write!(f, "{reason}"),
            Error::NoSuchFrame(index) => write!(f, "frame {index} is not in this video"),
        }
    }
}

/// Where one frame's sample lives, and whether a decoder can start there.
#[derive(Debug, Clone, Copy)]
struct Sample {
    offset: u32,
    size: u32,
    keyframe: bool,
}

impl Sample {
    fn bytes(self) -> [u8; 9] {
        let mut record = [0u8; 9];
        record[0..4].copy_from_slice(&self.offset.to_be_bytes());
        record[4..8].copy_from_slice(&self.size.to_be_bytes());
        record[8] = u8::from(self.keyframe);

        record
    }

    fn read(record: &[u8]) -> Self {
        Self {
            offset: u32::from_be_bytes([record[0], record[1], record[2], record[3]]),
            size: u32::from_be_bytes([record[4], record[5], record[6], record[7]]),
            keyframe: record[8] != 0,
        }
    }
}

/// A video being written: encoder, muxer, the file, and the index beside it.
pub struct Video {
    encoder: Encoder,
    /// `None` until the first frame, because the init segment needs the SPS and
    /// the PPS the encoder only emits with the first IDR.
    muxer: Option<FragmentedMuxer>,
    out: BufWriter<File>,
    index: BufWriter<File>,
    width: usize,
    height: usize,
    kind: Kind,
    settings: Settings,
    frames: u64,
    /// Bytes handed to `out` so far; a `BufWriter` has no position to ask.
    written: u64,
    /// Sizes and keyframe flags of the fragment being built: their offsets are
    /// only known once the fragment's bytes exist.
    pending: Vec<(u32, bool)>,
    /// A video being appended to cannot start with a P-frame: the fragment it
    /// would open has no parameter sets of its own. The first frame after a
    /// reopen is therefore an IDR whatever the caller said.
    needs_keyframe: bool,
    /// Sample buffer reused across frames: four bytes of length per NAL, and an
    /// intra frame at this size is well under a kilobyte.
    sample: Vec<u8>,
}

impl Video {
    /// Opens `path` for writing, appending the init segment on the first frame.
    ///
    /// `settings` is the whole of how this video is encoded.
    pub fn open(
        path: &Path,
        width: usize,
        height: usize,
        kind: Kind,
        settings: Settings,
    ) -> Result<Self, Error> {
        let mut config = EncoderConfig::baseline(width, height);
        config.qp = settings.qp;
        config.bitrate = settings.bitrate;
        config.framerate = settings.timescale() as f32;
        // The caller keys the frames it knows are discontinuities; this is only
        // the ceiling for a run that steps forever without one.
        config.gop_size = settings.gop_size.max(1);

        let encoder = Encoder::new(config).map_err(|e| Error::Encode(format!("{e:?}")))?;

        // A video this run already wrote — because a worker was restarted, or a
        // part was handed to another node — is continued, not overwritten. The
        // index is what says how many frames it holds, and it is written after
        // the frames it describes, so it never claims more than the file has.
        let (out, index, frames, written) = continue_or_create(path)?;

        Ok(Self {
            encoder,
            muxer: None,
            out,
            index,
            width,
            height,
            kind,
            settings,
            frames,
            written,
            pending: Vec::new(),
            needs_keyframe: frames > 0,
            sample: Vec::with_capacity(width * height),
        })
    }

    /// How many frames the video holds: what a step's picture is looked up by.
    pub fn frames(&self) -> u64 {
        self.frames
    }

    /// Appends one picture.
    ///
    /// `pixels` is `width * height` grey bytes or `width * height * 3` interleaved
    /// RGB bytes, row by row. `keyframe` asks for an IDR — and therefore for a
    /// fragment boundary — here.
    pub fn push(&mut self, pixels: &[u8], keyframe: bool) -> Result<(), Error> {
        let expected = self.width * self.height * self.kind.channels();

        if pixels.len() != expected {
            return Err(Error::FrameSize {
                expected,
                got: pixels.len(),
            });
        }

        let frame = match self.kind {
            Kind::Grey => grey_frame(pixels, self.width, self.height),
            Kind::Rgb => rgb_frame(pixels, self.width, self.height),
        };

        if keyframe || std::mem::take(&mut self.needs_keyframe) {
            self.encoder.request_keyframe();
        }

        let access_unit = self.encoder.encode(&frame);
        self.write_access_unit(&access_unit)
    }

    /// Ends the stream, draining the encoder and writing what is left.
    pub fn finish(&mut self) -> Result<(), Error> {
        // Baseline has no lookahead, so this is normally empty; it is the call
        // that makes the file complete for a configuration that buffers.
        let tail = self.encoder.flush();
        self.write_access_unit(&tail)?;
        self.flush_fragment()
    }

    /// Writes what is queued as a fragment now, so a frame just pushed can be
    /// read back. A keyframe flushes on its own; this is for a caller that needs
    /// the pictures readable before the next one arrives.
    pub fn flush(&mut self) -> Result<(), Error> {
        self.flush_fragment()
    }

    fn write_access_unit(&mut self, access_unit: &[u8]) -> Result<(), Error> {
        if access_unit.is_empty() {
            return Ok(());
        }

        let keyframe = contains_idr(access_unit);
        self.needs_keyframe = false;

        if self.muxer.is_none() {
            self.start_muxer(access_unit)?;
        }

        // Annex B into the muxer's length-prefixed shape, and the same bytes into
        // the index: a sample read back is the sample written.
        to_length_prefixed(access_unit, &mut self.sample);

        // `start_muxer` above either built it or answered with the reason it could
        // not. A NIF that panicked here would abort the whole VM, which no picture
        // is worth — so an absent muxer is one more error to hand back.
        let Some(muxer) = self.muxer.as_mut() else {
            return Err(Error::Mux("no muxer after the first frame's parameter sets".into()));
        };

        muxer
            .write_video(self.frames, self.frames, &self.sample, keyframe)
            .map_err(|e| Error::Mux(format!("{e:?}")))?;

        self.pending.push((self.sample.len() as u32, keyframe));
        self.frames += 1;

        if keyframe {
            self.flush_fragment()?;
        }

        Ok(())
    }

    /// Builds the muxer from the first access unit's own parameter sets, and
    /// writes the init segment — which is what makes the file playable before it
    /// is finished.
    fn start_muxer(&mut self, first: &[u8]) -> Result<(), Error> {
        let sps =
            nal_of_type(first, 7).ok_or_else(|| Error::Encode("no SPS in the first IDR".into()))?;
        let pps =
            nal_of_type(first, 8).ok_or_else(|| Error::Encode("no PPS in the first IDR".into()))?;

        let config = FragmentConfig {
            timescale: self.settings.timescale(),
            sps: sps.to_vec(),
            pps: pps.to_vec(),
            ..FragmentConfig::new(
                self.width as u32,
                self.height as u32,
                self.settings.timescale(),
            )
        };

        let mut muxer = FragmentedMuxer::new(config).map_err(|e| Error::Mux(format!("{e:?}")))?;

        let init = muxer.init_segment();
        self.write_out(&init)
            .map_err(|e| Error::Io(format!("init segment: {e}")))?;

        self.muxer = Some(muxer);

        Ok(())
    }

    /// Writes everything queued as one `moof`+`mdat`, then the index entries
    /// that say where each of its frames landed.
    ///
    /// In that order: an index naming bytes the file does not hold is worse than
    /// an index that stops early, because a reader would trust it.
    fn flush_fragment(&mut self) -> Result<(), Error> {
        let Some(muxer) = self.muxer.as_mut() else {
            return Ok(());
        };

        let Some(segment) = muxer.flush_segment() else {
            return Ok(());
        };

        let payload =
            media_payload(&segment).ok_or_else(|| Error::Mux("a fragment with no mdat".into()))?;

        let mut offset = (self.written + payload as u64) as u32;

        for (size, keyframe) in std::mem::take(&mut self.pending) {
            self.index
                .write_all(&Sample { offset, size, keyframe }.bytes())
                .map_err(|e| Error::Io(format!("index: {e}")))?;
            offset += size;
        }

        self.index
            .flush()
            .map_err(|e| Error::Io(format!("index: {e}")))?;

        self.write_out(&segment)
            .map_err(|e| Error::Io(format!("fragment: {e}")))
    }

    fn write_out(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        self.out.write_all(bytes)?;
        self.out.flush()?;
        self.written += bytes.len() as u64;

        Ok(())
    }
}

impl Drop for Video {
    /// A file that was never finished still ends where the last complete
    /// fragment ends, so a killed run leaves a video of what it did.
    fn drop(&mut self) {
        let _ = self.finish();
    }
}

/// Where a video's index is kept: beside it, named after it.
pub fn index_path(video: &Path) -> PathBuf {
    let mut name = video.as_os_str().to_os_string();
    name.push(".index");

    PathBuf::from(name)
}

/// The video file, its index, and how much of each is already written.
///
/// A file with no index — a crash between creating the video and writing the
/// first frame — is started over: nothing in it can be read back, so continuing
/// would produce a file whose frames the index cannot name.
fn continue_or_create(video: &Path) -> Result<(BufWriter<File>, BufWriter<File>, u64, u64), Error> {
    let index = index_path(video);
    let indexed = std::fs::metadata(&index).map(|meta| meta.len()).unwrap_or(0);
    let continuing = indexed >= 9 && video.exists();

    let open = |path: &Path| -> Result<File, Error> {
        if continuing {
            OpenOptions::new()
                .append(true)
                .open(path)
                .map_err(|e| Error::Io(format!("{path:?}: {e}")))
        } else {
            File::create(path).map_err(|e| Error::Io(format!("{path:?}: {e}")))
        }
    };

    let out = open(video)?;
    let index = open(&index)?;
    let written = if continuing {
        out.metadata()
            .map_err(|e| Error::Io(format!("{video:?}: {e}")))?
            .len()
    } else {
        0
    };

    Ok((
        BufWriter::new(out),
        BufWriter::new(index),
        if continuing { indexed / 9 } else { 0 },
        written,
    ))
}

/// How many frames a video on disk holds, read off its index.
///
/// Zero for a video that has none, and for one whose index is not there: a file
/// nobody can name the frames of is a file nobody can read a frame out of.
pub fn frames_in(video: &Path) -> u64 {
    std::fs::metadata(index_path(video)).map_or(0, |meta| meta.len() / 9)
}

/// A frame read back: the pixels as the camera drew them, not as the codec
/// stores them.
pub struct Decoded {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

/// One frame of `video`, decoded from the keyframe it depends on.
///
/// This is what lets the video be the *only* artifact: a page asking for a
/// step's picture gets the bytes it would have got from the PNG that step used
/// to write.
pub fn frame_at(video: &Path, index: u64, kind: Kind) -> Result<Decoded, Error> {
    let samples = read_index(video)?;

    let Some(position) = usize::try_from(index).ok().filter(|at| *at < samples.len()) else {
        return Err(Error::NoSuchFrame(index));
    };

    // A picture depends on every frame since its keyframe, so a seek decodes at
    // most one fragment — which is why the writer keys at least every `gop`
    // frames.
    let start = samples[..=position]
        .iter()
        .rposition(|sample| sample.keyframe)
        .ok_or(Error::NoSuchFrame(index))?;

    let mut file = File::open(video).map_err(|e| Error::Io(format!("{video:?}: {e}")))?;
    let length = file
        .metadata()
        .map_err(|e| Error::Io(format!("{video:?}: {e}")))?
        .len();
    let mut decoder = Decoder::new();
    let mut picture: Option<YuvFrame> = None;

    for sample in &samples[start..=position] {
        let annex_b = read_sample(&mut file, sample, length)?;

        match decoder.decode(&annex_b) {
            Ok(Some(frame)) => picture = Some(frame),
            Ok(None) => {}
            Err(e) => return Err(Error::Encode(format!("{e:?}"))),
        }
    }

    let frame = picture.ok_or(Error::NoSuchFrame(index))?;

    Ok(Decoded {
        width: frame.width,
        height: frame.height,
        pixels: match kind {
            Kind::Grey => expand(frame.y.iter().copied()),
            Kind::Rgb => to_rgb(&frame),
        },
    })
}

fn read_index(video: &Path) -> Result<Vec<Sample>, Error> {
    let bytes = std::fs::read(index_path(video)).map_err(|e| Error::Io(format!("index: {e}")))?;

    Ok(bytes.chunks_exact(9).map(Sample::read).collect())
}

fn read_sample(file: &mut File, sample: &Sample, length: u64) -> Result<Vec<u8>, Error> {
    // The index is a file like any other and can be corrupt: one record must not
    // be able to ask for four gigabytes, or to read past the video it describes.
    let end = u64::from(sample.offset).saturating_add(u64::from(sample.size));

    if end > length {
        return Err(Error::Io(format!(
            "sample at {} of {} bytes is past the end of a video of {length}",
            sample.offset, sample.size
        )));
    }

    let mut raw = vec![0u8; sample.size as usize];

    file.seek(SeekFrom::Start(sample.offset as u64))
        .and_then(|_| file.read_exact(&mut raw))
        .map_err(|e| Error::Io(format!("sample at {}: {e}", sample.offset)))?;

    Ok(from_length_prefixed(&raw))
}

/// The luma a decoder hands back is in the 16–235 band; a depth picture is drawn
/// in 0–255, which is the band the camera produced.
fn expand(luma: impl Iterator<Item = u8>) -> Vec<u8> {
    luma.map(|value| {
        let above = u32::from(value.saturating_sub(16));
        (above * 255 / 219).min(255) as u8
    })
    .collect()
}

/// YUV back to the RGB a colour picture was made of, by the inverse of the
/// conversion in `annexb`.
fn to_rgb(frame: &YuvFrame) -> Vec<u8> {
    let (width, height) = (frame.width, frame.height);
    let stride = width / 2;
    let mut rgb = Vec::with_capacity(width * height * 3);

    for row in 0..height {
        for column in 0..width {
            let luma = i32::from(frame.y[row * width + column]) - 16;
            let chroma = (row / 2) * stride + column / 2;
            let blue = i32::from(frame.u.get(chroma).copied().unwrap_or(128)) - 128;
            let red = i32::from(frame.v.get(chroma).copied().unwrap_or(128)) - 128;

            rgb.push(clamp_byte((298 * luma + 409 * red + 128) >> 8));
            rgb.push(clamp_byte((298 * luma - 100 * blue - 208 * red + 128) >> 8));
            rgb.push(clamp_byte((298 * luma + 516 * blue + 128) >> 8));
        }
    }

    rgb
}

fn clamp_byte(value: i32) -> u8 {
    value.clamp(0, 255) as u8
}

/// Where the fragment's `mdat` payload starts — the first byte of its first
/// sample. Walked rather than assumed, because the order of a fragment's boxes
/// is the muxer's to choose.
fn media_payload(segment: &[u8]) -> Option<usize> {
    let mut at = 0;

    while at + 8 <= segment.len() {
        let size =
            u32::from_be_bytes([segment[at], segment[at + 1], segment[at + 2], segment[at + 3]])
                as usize;
        let kind = &segment[at + 4..at + 8];

        if kind == b"mdat" {
            return Some(at + 8);
        }

        if size < 8 {
            return None;
        }

        at += size;
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What a decoder hands back for a colour picture made of one colour: the
    /// encoder converts RGB to limited-range YUV, so the round trip is the test
    /// that the conversion has every term it needs.
    fn round_trip(r: u8, g: u8, b: u8) -> (u8, u8, u8) {
        let pixels = [r, g, b].repeat(4);
        let frame = rgb_frame(&pixels, 2, 2);
        let rgb = to_rgb(&frame);
        (rgb[0], rgb[1], rgb[2])
    }

    fn assert_close(colour: (u8, u8, u8)) {
        let (r, g, b) = colour;
        let back = round_trip(r, g, b);
        let (back_r, back_g, back_b) = back;

        assert!(
            (i32::from(back_r) - i32::from(r)).abs() <= 4
                && (i32::from(back_g) - i32::from(g)).abs() <= 4
                && (i32::from(back_b) - i32::from(b)).abs() <= 4,
            "a picture of {colour:?} came back as {back:?}"
        );
    }

    /// The same question through the codec, and through one frame a colour:
    /// a 2 × 2 picture is a single chroma sample, so a frame of four different
    /// colours averages to neutral and would test nothing.
    #[test]
    fn a_colour_frame_survives_the_video() {
        let path = std::env::temp_dir().join("frame_video_colour_roundtrip.mp4");
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(path.with_extension("mp4.index"));

        let palette = [[255u8, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]];

        let mut video =
            Video::open(&path, 2, 2, Kind::Rgb, Settings::default()).expect("a video opens");

        for (index, colour) in palette.into_iter().enumerate() {
            let pixels = colour.repeat(4);
            video.push(&pixels, index == 0).expect("a frame is taken");
        }

        video.finish().expect("the video closes");

        for (index, drawn) in palette.into_iter().enumerate() {
            let decoded =
                frame_at(&path, index as u64, Kind::Rgb).expect("the frame is there");

            for replayed in decoded.pixels.chunks_exact(3) {
                for (a, b) in drawn.into_iter().zip(replayed.iter().copied()) {
                    assert!(
                        i32::from(a).abs_diff(i32::from(b)) <= 6,
                        "frame {index}: {drawn:?} came back as {replayed:?}"
                    );
                }
            }
        }
    }

    /// The palette is the one that catches a missing term in the matrix: a
    /// colour with no red and no blue — green — is neutral chroma if the green
    /// coefficient is not there, and white is strongly shifted.
    #[test]
    fn a_colour_survives_the_round_trip() {
        for colour in [
            (0u8, 0u8, 0u8),
            (255, 255, 255),
            (255, 0, 0),
            (0, 255, 0),
            (0, 0, 255),
            (255, 255, 0),
            (0, 255, 255),
            (255, 0, 255),
            (128, 128, 128),
            (200, 110, 60),
            (60, 130, 90),
        ] {
            assert_close(colour);
        }
    }
}
