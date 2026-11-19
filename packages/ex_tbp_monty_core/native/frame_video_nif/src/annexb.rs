//! The arithmetic between a caller's pixels and the encoder: Annex B ↔ length
//! prefixes, one channel or three, and where the keyframes are.

use rusty_h264::YuvFrame;

/// A depth picture: one value a pixel is luma, and the colour planes say
/// "grey". Nothing is subsampled that carries a number, so a depth frame's only
/// loss is the quantiser.
///
/// The value is squeezed into the 16–235 band a video decoder expands back to
/// full range: a picture written raw would lose its darkest and brightest parts
/// to clipping, and a depth image is mostly a range of greys.
pub fn grey_frame(pixels: &[u8], width: usize, height: usize) -> YuvFrame {
    let chroma = neutral_chroma(width, height);

    YuvFrame {
        width,
        height,
        y: pixels.iter().map(|value| luma_of_grey(*value)).collect(),
        u: chroma.0,
        v: chroma.1,
    }
}

/// Where a grey value lands in the limited-range band, and back again: the
/// decoder's own expansion is the inverse of this.
pub fn luma_of_grey(value: u8) -> u8 {
    clamp(((value as u32 * 219 + 127) / 255) + 16)
}

/// A colour picture: BT.601 limited-range luma, and the two chroma planes
/// averaged over 2 × 2 blocks. Chroma is a quarter of the information in this
/// profile, which is the price of every player on every platform decoding it in
/// hardware.
pub fn rgb_frame(pixels: &[u8], width: usize, height: usize) -> YuvFrame {
    let (cw, ch) = (width / 2, height / 2);
    let mut y = Vec::with_capacity(width * height);
    let mut u = Vec::with_capacity(cw * ch);
    let mut v = Vec::with_capacity(cw * ch);

    for row in 0..height {
        for column in 0..width {
            let at = (row * width + column) * 3;
            y.push(luma(pixels[at], pixels[at + 1], pixels[at + 2]));
        }
    }

    // One chroma sample per 2 × 2 block: average the four conversions rather
    // than convert the average, which is the same answer at a lower cost.
    for row in (0..height).step_by(2) {
        for column in (0..width).step_by(2) {
            let mut cb = 0u32;
            let mut cr = 0u32;

            for (dr, dc) in [(0usize, 0usize), (0, 1), (1, 0), (1, 1)] {
                let at = ((row + dr) * width + column + dc) * 3;
                let (b, r) = (pixels[at + 2] as u32, pixels[at] as u32);
                cb += chroma_blue(b, r);
                cr += chroma_red(b, r);
            }

            u.push(((cb + 2) / 4) as u8);
            v.push(((cr + 2) / 4) as u8);
        }
    }

    YuvFrame {
        width,
        height,
        y,
        u,
        v,
    }
}

/// BT.601 luma, limited range: the 16–235 band a video decoder expects.
fn luma(r: u8, g: u8, b: u8) -> u8 {
    clamp(((66 * r as u32 + 129 * g as u32 + 25 * b as u32 + 128) >> 8) + 16)
}

fn chroma_blue(b: u32, r: u32) -> u32 {
    (((112 * b).saturating_sub(38 * r) + 128) >> 8) + 128
}

fn chroma_red(b: u32, r: u32) -> u32 {
    (((112 * r).saturating_sub(18 * b) + 128) >> 8) + 128
}

fn clamp(value: u32) -> u8 {
    value.min(255) as u8
}

fn neutral_chroma(width: usize, height: usize) -> (Vec<u8>, Vec<u8>) {
    let samples = (width / 2) * (height / 2);
    (vec![128; samples], vec![128; samples])
}

/// The NAL units of an Annex B access unit, without start codes — the payload
/// as the muxer's length-prefixed samples want it.
pub fn nal_units(access_unit: &[u8]) -> Vec<&[u8]> {
    let mut units = Vec::new();
    let mut payload: Option<usize> = None;
    let mut at = 0;

    while at + 3 <= access_unit.len() {
        let code = if access_unit[at..].starts_with(&[0, 0, 0, 1]) {
            Some(4)
        } else if access_unit[at..].starts_with(&[0, 0, 1]) {
            Some(3)
        } else {
            None
        };

        match code {
            Some(length) => {
                if let Some(start) = payload {
                    units.push(trim(&access_unit[start..at]));
                }

                at += length;
                payload = Some(at);
            }
            None => at += 1,
        }
    }

    if let Some(start) = payload {
        units.push(trim(&access_unit[start..]));
    }

    units
}

/// A NAL's payload ends before the zeros that padded it out to the next start
/// code.
fn trim(nal: &[u8]) -> &[u8] {
    let end = nal.iter().rposition(|byte| *byte != 0).map_or(0, |last| last + 1);
    &nal[..end]
}

/// Whether this access unit holds an IDR — which makes it a sync sample, and a
/// fragment boundary. Read off the bitstream rather than trusted from a flag:
/// the encoder decides, and its answer is what the file says.
pub fn contains_idr(access_unit: &[u8]) -> bool {
    nal_units(access_unit)
        .iter()
        .any(|nal| nal_type(nal) == Some(5))
}

/// The first parameter-set NAL of `kind` (7 SPS, 8 PPS), which the init segment
/// needs before any picture can be played.
pub fn nal_of_type<'a>(access_unit: &'a [u8], kind: u8) -> Option<&'a [u8]> {
    nal_units(access_unit)
        .into_iter()
        .find(|nal| nal_type(nal) == Some(kind))
}

fn nal_type(nal: &[u8]) -> Option<u8> {
    nal.first().map(|header| header & 0x1f)
}

/// The muxer's sample format: each NAL preceded by its length, big-endian.
pub fn to_length_prefixed(access_unit: &[u8], into: &mut Vec<u8>) {
    into.clear();

    for nal in nal_units(access_unit) {
        into.extend_from_slice(&(nal.len() as u32).to_be_bytes());
        into.extend_from_slice(nal);
    }
}

/// Back to Annex B, which is the only shape the decoder reads.
pub fn from_length_prefixed(sample: &[u8]) -> Vec<u8> {
    let mut annex_b = Vec::with_capacity(sample.len() + 16);
    let mut at = 0;

    while at + 4 <= sample.len() {
        let length = u32::from_be_bytes([sample[at], sample[at + 1], sample[at + 2], sample[at + 3]])
            as usize;
        let start = at + 4;
        let end = start + length;

        if end > sample.len() {
            break;
        }

        annex_b.extend_from_slice(&[0, 0, 0, 1]);
        annex_b.extend_from_slice(&sample[start..end]);
        at = end;
    }

    annex_b
}
