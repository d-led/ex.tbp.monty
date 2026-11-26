//! The per-pixel kernels a salience pyramid spends its seconds on: the bicubic
//! enlargement, SLIC's k-means, and the Gaussian blur every channel passes
//! through.
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
    let pixels = decode(source.as_slice(), source_width * source_height)?;

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

/// A `width` by `height` plane blurred with a Gaussian of `sigma`.
///
/// The kernel is sized as Monty sizes it — `round(2 * truncate * sigma + 1)`,
/// forced odd — and applied as OpenCV applies it: across each row, then down
/// each column, with the edge pixel repeated outward. Three colour channels and
/// SLIC's smoothing call it; on a 256-square plane the Elixir takes 21.6 ms.
///
/// `Images.gaussian_blur_reference/3` is the reference, and every number here is
/// the same `f64` operation in the same order: the same weights, normalised by
/// the same left-to-right total, the same folded symmetric pairs, the same
/// `centre + weight * (left + right)` accumulation. The two planes are bit for
/// bit equal, which a parity case holds them to on several shapes.
#[rustler::nif(schedule = "DirtyCpu")]
fn blur<'a>(
    env: Env<'a>,
    plane: Binary,
    width: usize,
    height: usize,
    sigma: f64,
    truncate: f64,
) -> Result<Term<'a>, rustler::Error> {
    let pixels = decode(plane.as_slice(), width * height)?;

    let kernel = gaussian_kernel(sigma, truncate);
    let across = windows(&kernel, width);
    let down = windows(&kernel, height);

    let mut horizontal = vec![0.0f64; width * height];

    for row in 0..height {
        let line = &pixels[row * width..(row + 1) * width];

        for column in 0..width {
            horizontal[row * width + column] = blurred(&across[column], line, 1);
        }
    }

    let mut binary = NewBinary::new(env, width * height * std::mem::size_of::<f64>());
    let out = binary.as_mut_slice();

    for row in 0..height {
        for column in 0..width {
            // The column's values from the first pass, read with the width as
            // the stride: `values[index]` is `horizontal[index][column]`.
            let value = blurred(&down[row], &horizontal[column..], width);

            let offset = (row * width + column) * std::mem::size_of::<f64>();
            out[offset..offset + std::mem::size_of::<f64>()].copy_from_slice(&value.to_le_bytes());
        }
    }

    Ok(Term::from(binary))
}

/// The plane as `f64`s, or `:badarg` — a binary of the wrong length would
/// otherwise read past its end.
fn decode(values: &[u8], pixels: usize) -> Result<Vec<f64>, rustler::Error> {
    if values.len() != pixels * std::mem::size_of::<f64>() {
        return Err(rustler::Error::BadArg);
    }

    Ok(values
        .chunks_exact(std::mem::size_of::<f64>())
        .map(|bytes| f64::from_le_bytes(bytes.try_into().expect("eight bytes")))
        .collect())
}

/// Monty's Gaussian: sampled at integer offsets, then normalised by its own
/// total, summed left to right as `Enum.sum/1` sums it.
fn gaussian_kernel(sigma: f64, truncate: f64) -> Vec<f64> {
    let mut size = (2.0 * truncate * sigma + 1.0).round() as isize;

    if size % 2 == 0 {
        size += 1;
    }

    let pad = (size / 2).max(0);

    let mut weights: Vec<f64> = (-pad..=pad)
        .map(|offset| {
            let offset = offset as f64;
            (-(offset * offset) / (2.0 * sigma * sigma)).exp()
        })
        .collect();

    let total = weights.iter().fold(0.0f64, |sum, weight| sum + weight);

    for weight in &mut weights {
        *weight /= total;
    }

    weights
}

/// One position's window: the centre tap, and the symmetric pairs around it,
/// each clamped to the edge — `BORDER_REPLICATE`, the edge pixel repeated.
struct Window {
    middle: usize,
    middle_weight: f64,
    pairs: Vec<(usize, usize, f64)>,
}

fn windows(weights: &[f64], length: usize) -> Vec<Window> {
    let pad = weights.len() / 2;
    let last = length as isize - 1;
    let at = |position: isize| clamp(position, 0, last) as usize;

    (0..length)
        .map(|position| {
            let position = position as isize;

            Window {
                middle: at(position),
                middle_weight: weights[pad],
                pairs: (0..pad)
                    .map(|tap| {
                        let tap = tap as isize;

                        (
                            at(position + tap - pad as isize),
                            at(position + (2 * pad as isize - tap) - pad as isize),
                            weights[tap as usize],
                        )
                    })
                    .collect(),
            }
        })
        .collect()
}

/// The centre term plus each symmetric pair: the same sum as the windowed dot
/// product, with half the work.
fn blurred(window: &Window, values: &[f64], step: usize) -> f64 {
    let mut sum = window.middle_weight * values[window.middle * step];

    for (left, right, weight) in &window.pairs {
        sum += weight * (values[left * step] + values[right * step]);
    }

    sum
}

/// SLIC's connectivity pass: every label becomes one connected blob, and a blob
/// smaller than `min_size` is absorbed into the neighbour it borders.
///
/// `SlicMerge.enforce_connectivity_reference/5` is the reference and holds the
/// same walk: index order, the `+x, -x, +y, -y` neighbour order, the
/// `max_size` cut that discards the rest of the queue, and `min_size` deciding
/// between "absorb" and "next label". The two differences are shape, not
/// numbers: a queue that advances instead of two lists appended on every pixel
/// (which was O(n²) a blob) and no persistent array (whose every write copies a
/// path).
#[rustler::nif(schedule = "DirtyCpu")]
fn enforce_connectivity<'a>(
    env: Env<'a>,
    labels: Binary,
    width: usize,
    height: usize,
    min_size: usize,
    max_size: usize,
) -> Result<Term<'a>, rustler::Error> {
    let size = width * height;

    if labels.as_slice().len() != size * std::mem::size_of::<u32>() {
        return Err(rustler::Error::BadArg);
    }

    let label_of: Vec<u32> = labels
        .as_slice()
        .chunks_exact(std::mem::size_of::<u32>())
        .map(|bytes| u32::from_le_bytes(bytes.try_into().expect("four bytes")))
        .collect();

    let mut connected: Vec<i64> = vec![-1; size];
    let mut next_label: i64 = 0;
    let mut coordinates: Vec<usize> = Vec::new();
    let mut queue: std::collections::VecDeque<usize> = std::collections::VecDeque::new();

    for index in 0..size {
        if connected[index] > -1 {
            continue;
        }

        let label = label_of[index];
        let new_label = next_label;

        connected[index] = new_label;
        coordinates.clear();
        queue.clear();
        coordinates.push(index);
        queue.push_back(index);

        let mut adjacent = new_label;

        while !queue.is_empty() && coordinates.len() < max_size {
            let from = queue.pop_front().expect("the queue is not empty");

            for neighbour in neighbours(from, width) {
                let claimed = connected[neighbour];

                if claimed == -1 && label_of[neighbour] == label {
                    connected[neighbour] = new_label;
                    coordinates.push(neighbour);
                    queue.push_back(neighbour);
                } else if claimed > -1 && claimed != new_label {
                    adjacent = claimed;
                }
            }
        }

        if coordinates.len() < min_size {
            for &coordinate in &coordinates {
                connected[coordinate] = adjacent;
            }
        } else {
            next_label += 1;
        }
    }

    let mut binary = NewBinary::new(env, size * std::mem::size_of::<u32>());
    let out = binary.as_mut_slice();

    for (index, &label) in connected.iter().enumerate() {
        let offset = index * std::mem::size_of::<u32>();
        out[offset..offset + std::mem::size_of::<u32>()]
            .copy_from_slice(&(label as u32).to_le_bytes());
    }

    Ok(Term::from(binary))
}

/// `+x, -x, +y, -y` in that order: `skimage`'s order with the two z neighbours
/// dropped, because a view is one pixel deep. The bounds are checked against
/// `width` on both axes, as the reference checks them — a view is square.
fn neighbours(index: usize, width: usize) -> Vec<usize> {
    let row = (index / width) as isize;
    let column = (index % width) as isize;
    let last = width as isize - 1;

    [(0, 1), (0, -1), (1, 0), (-1, 0)]
        .iter()
        .map(|(d_row, d_column)| (row + d_row, column + d_column))
        .filter(|(r, c)| *r >= 0 && *r <= last && *c >= 0 && *c <= last)
        .map(|(r, c)| (r * width as isize + c) as usize)
        .collect()
}

rustler::init!("Elixir.ExTbpMonty.Core.SalienceNif");

/// SLIC's k-means: which seed each pixel belongs to, after at most `max_iter`
/// passes, as one `u32` per pixel.
///
/// `SlicMerge`'s own loop is the reference (`SlicMerge.segment_image_reference/2`).
/// The arithmetic is the same in both — the same window (`trunc(centre) ±
/// 2 * step`), the same strictly-greater test against the distance so far, the
/// same `(dy * dy + dx * dx) * spatial_factor + colour distance`, the same
/// re-centring in pixel order — and a parity case holds the two label fields to
/// each other on views of several shapes.
///
/// `pixels` is `width * height` colours of three `f64`s, already scaled by
/// `1/compactness`; `seeds` is five `f64` each (`y`, `x`, `r`, `g`, `b`).
#[rustler::nif(schedule = "DirtyCpu")]
fn slic_labels<'a>(
    env: Env<'a>,
    pixels: Binary,
    width: usize,
    seeds: Binary,
    step_y: i64,
    step_x: i64,
    spatial_factor: f64,
    max_iter: usize,
) -> Result<Term<'a>, rustler::Error> {
    let bytes_per_pixel = std::mem::size_of::<f64>() * 3;

    if width == 0 || pixels.len() % (width * bytes_per_pixel) != 0 || seeds.len() % 40 != 0 {
        return Err(rustler::Error::BadArg);
    }

    let height = pixels.len() / (width * bytes_per_pixel);
    let points: Vec<f64> = pixels
        .as_slice()
        .chunks_exact(std::mem::size_of::<f64>())
        .map(|bytes| f64::from_le_bytes(bytes.try_into().expect("eight bytes")))
        .collect();

    let mut centres: Vec<Seed> = seeds
        .as_slice()
        .chunks_exact(5 * std::mem::size_of::<f64>())
        .map(|chunk| {
            let mut numbers = [0.0f64; 5];
            for (slot, bytes) in chunk.chunks_exact(std::mem::size_of::<f64>()).enumerate() {
                numbers[slot] = f64::from_le_bytes(bytes.try_into().expect("eight bytes"));
            }
            Seed { y: numbers[0], x: numbers[1], colour: [numbers[2], numbers[3], numbers[4]], dead: false }
        })
        .collect();

    let labels = k_means(&points, width, height, &mut centres, step_y, step_x, spatial_factor, max_iter);

    let mut binary = NewBinary::new(env, labels.len() * std::mem::size_of::<u32>());
    let out = binary.as_mut_slice();

    for (index, label) in labels.iter().enumerate() {
        let offset = index * std::mem::size_of::<u32>();
        out[offset..offset + std::mem::size_of::<u32>()].copy_from_slice(&(*label as u32).to_le_bytes());
    }

    Ok(Term::from(binary))
}

struct Seed {
    y: f64,
    x: f64,
    colour: [f64; 3],
    dead: bool,
}

/// `DBL_MAX`: the distance every pixel starts at, so the first seed to reach a
/// pixel takes it.
const UNCLAIMED: f64 = f64::MAX;

#[allow(clippy::too_many_arguments)]
fn k_means(
    points: &[f64],
    width: usize,
    height: usize,
    centres: &mut [Seed],
    step_y: i64,
    step_x: i64,
    spatial_factor: f64,
    max_iter: usize,
) -> Vec<u32> {
    let mut labels = vec![0u32; width * height];
    let mut distances = vec![UNCLAIMED; width * height];

    for _ in 0..max_iter {
        distances.fill(UNCLAIMED);
        let mut changed = false;

        for (k, seed) in centres.iter().enumerate() {
            if seed.dead {
                continue;
            }

            let Some((low_y, high_y)) = window(seed.y, step_y, height) else { continue };
            let Some((low_x, high_x)) = window(seed.x, step_x, width) else { continue };

            for y in low_y..=high_y {
                for x in low_x..=high_x {
                    let index = y * width + x;
                    let colour = [
                        points[index * 3],
                        points[index * 3 + 1],
                        points[index * 3 + 2],
                    ];

                    let dy = seed.y - y as f64;
                    let dx = seed.x - x as f64;
                    let distance = (dy * dy + dx * dx) * spatial_factor + squared_distance(&colour, &seed.colour);

                    if distances[index] > distance {
                        labels[index] = k as u32;
                        distances[index] = distance;
                        changed = true;
                    }
                }
            }
        }

        if !changed {
            break;
        }

        recentre(points, width, height, centres, &labels);
    }

    labels
}

/// `[centre - 2*step, centre + 2*step]`, clipped to the plane; `None` when the
/// clipping leaves nothing.
fn window(centre: f64, step: i64, size: usize) -> Option<(usize, usize)> {
    let centre = centre as i64;
    let low = (centre - 2 * step).max(0);
    let high = (centre + 2 * step + 1).min(size as i64) - 1;

    if high < low {
        None
    } else {
        Some((low as usize, high as usize))
    }
}

fn squared_distance(left: &[f64; 3], right: &[f64; 3]) -> f64 {
    let dr = left[0] - right[0];
    let dg = left[1] - right[1];
    let db = left[2] - right[2];

    dr * dr + dg * dg + db * db
}

/// Every centroid becomes the mean of the pixels it won; one that won none is
/// dead, exactly as the reference marks it.
fn recentre(points: &[f64], width: usize, height: usize, centres: &mut [Seed], labels: &[u32]) {
    let mut totals: std::collections::HashMap<u32, (f64, f64, f64, [f64; 3])> =
        std::collections::HashMap::new();

    for index in 0..width * height {
        let total = totals.entry(labels[index]).or_insert((0.0, 0.0, 0.0, [0.0; 3]));

        total.0 += 1.0;
        total.1 += (index / width) as f64;
        total.2 += (index % width) as f64;
        total.3[0] += points[index * 3];
        total.3[1] += points[index * 3 + 1];
        total.3[2] += points[index * 3 + 2];
    }

    for (k, seed) in centres.iter_mut().enumerate() {
        match totals.get(&(k as u32)) {
            None => seed.dead = true,
            Some((count, y, x, colour)) => {
                seed.y = y / count;
                seed.x = x / count;
                seed.colour = [colour[0] / count, colour[1] / count, colour[2] / count];
            }
        }
    }
}
