//! The bicubic enlargement a salience pyramid spends its seconds on.
//!
//! `Images.resize/3` with `:cubic` is called once per octave when a pyramid is
//! collapsed, and each call is sixteen multiply-adds for every destination
//! pixel: on a 256-square view that is 16.8 million taps a step, and Elixir runs
//! them at about 20 million ops a second — one second of a five-second step, and
//! the same again for every colour channel.
//!
//! The Elixir implementation stays the reference (`Images.cubic_reference/3`):
//! it is what the tests describe, what runs where no Rust toolchain built this,
//! and what this is held to by a parity test that compares the two bit for bit.
//!
//! ## Why the answer is bit-identical
//!
//! Every number here is the same `f64` operation, in the same order, as the
//! Elixir: the same coordinate, the same four cubic weights (OpenCV's, `A =
//! -0.75`), the same clamped taps, the same `(wy * wx) * value` and the same
//! accumulation from `0.0`. Nothing is re-associated, so a label, an evidence
//! value or a digest downstream cannot tell which side produced the plane.
//!
//! ## The shape of the call
//!
//! One plane in, one plane out, both flat little-endian `f64`: a 256-square
//! view is 512 KiB, and encoding 65 536 Elixir floats per octave would cost more
//! than the taps being saved. The call is on a dirty CPU scheduler, because it
//! holds its scheduler for the whole plane.

use rustler::{Binary, Env, NewBinary, Term};

/// OpenCV's cubic constant, the one `skimage`'s `resize` uses for `:cubic`.
const CUBIC_A: f64 = -0.75;

/// The only answer that means "this crate is loaded": a NIF that is not there
/// raises, so `loaded?/0` in Elixir can tell the two apart without an error
/// value a caller might ignore.
#[rustler::nif]
fn available() -> bool {
    true
}

/// A `width` by `height` plane resampled from `source` (row-major `f64`).
///
/// Fails with `:badarg` when `source` is not `source_width * source_height`
/// values: a binary of the wrong length would otherwise read past its end.
#[rustler::nif(schedule = "DirtyCpu")]
fn enlarge_cubic<'a>(
    env: Env<'a>,
    source: Binary,
    source_width: usize,
    source_height: usize,
    width: usize,
    height: usize,
) -> Result<Term<'a>, rustler::Error> {
    let values = source.as_slice();

    if values.len() != source_width * source_height * std::mem::size_of::<f64>() {
        return Err(rustler::Error::BadArg);
    }

    let pixels: Vec<f64> = values
        .chunks_exact(std::mem::size_of::<f64>())
        .map(|bytes| f64::from_le_bytes(bytes.try_into().expect("eight bytes")))
        .collect();

    let mut binary = NewBinary::new(env, width * height * std::mem::size_of::<f64>());
    let out = binary.as_mut_slice();

    let vertical: Vec<([usize; 4], [f64; 4])> = (0..height)
        .map(|row| cubic_taps(row, height, source_height))
        .collect();
    let horizontal: Vec<([usize; 4], [f64; 4])> = (0..width)
        .map(|column| cubic_taps(column, width, source_width))
        .collect();

    for row in 0..height {
        let (offsets_y, weights_y) = vertical[row];

        for column in 0..width {
            let (offsets_x, weights_x) = horizontal[column];
            let sample = weighted(&pixels, source_width, &offsets_x, &weights_x, &offsets_y, &weights_y);

            let offset = (row * width + column) * std::mem::size_of::<f64>();
            out[offset..offset + std::mem::size_of::<f64>()].copy_from_slice(&sample.to_le_bytes());
        }
    }

    Ok(Term::from(binary))
}

/// The four source rows, each weighted by the four source columns it reads —
/// the same two nested sums, in the same order, as `Images.weighted/4`.
#[allow(clippy::too_many_arguments)]
fn weighted(
    pixels: &[f64],
    source_width: usize,
    offsets_x: &[usize; 4],
    weights_x: &[f64; 4],
    offsets_y: &[usize; 4],
    weights_y: &[f64; 4],
) -> f64 {
    let mut sum = 0.0f64;

    for tap_y in 0..4 {
        let row = offsets_y[tap_y] * source_width;
        let mut across = 0.0f64;

        for tap_x in 0..4 {
            across += weights_y[tap_y] * weights_x[tap_x] * pixels[row + offsets_x[tap_x]];
        }

        sum += across;
    }

    sum
}

/// The four taps a destination coordinate reads, as source indices and weights.
fn cubic_taps(index: usize, destination: usize, source: usize) -> ([usize; 4], [f64; 4]) {
    let coordinate = (index as f64 + 0.5) * source as f64 / destination as f64 - 0.5;
    let nearest = coordinate.floor();
    let fraction = coordinate - nearest;

    let mut offsets = [0usize; 4];

    for (slot, position) in (-1..=2).enumerate() {
        offsets[slot] = clamp(nearest as isize + position, 0, source as isize - 1) as usize;
    }

    (offsets, cubic_weights(fraction))
}

fn clamp(value: isize, low: isize, high: isize) -> isize {
    value.max(low).min(high)
}

/// OpenCV's cubic weights for a fractional position, with `A = -0.75`.
///
/// Written as the same polynomial, in the same order, as the Elixir: the last
/// weight is the remainder, which is what makes the four sum to one.
fn cubic_weights(x: f64) -> [f64; 4] {
    let first =
        ((CUBIC_A * (x + 1.0) - 5.0 * CUBIC_A) * (x + 1.0) + 8.0 * CUBIC_A) * (x + 1.0) - 4.0 * CUBIC_A;
    let second = ((CUBIC_A + 2.0) * x - (CUBIC_A + 3.0)) * x * x + 1.0;
    let third = ((CUBIC_A + 2.0) * (1.0 - x) - (CUBIC_A + 3.0)) * (1.0 - x) * (1.0 - x) + 1.0;

    [first, second, third, 1.0 - first - second - third]
}

rustler::init!("Elixir.ExTbpMonty.Core.SalienceNif");
