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

use rustler::{Binary, Encoder, Env, NewBinary, Term};

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

/// A plane blurred with a Gaussian of `sigma`: the body of `blur/5` without the
/// binary in and out, so the channel kernel can blur a plane it already holds.
///
/// Both passes walk a row at a time. The second one used to read a column at a
/// stride of `width` — a fresh subslice and a per-pixel walk of the window's
/// pairs — and read 0.47 ms on a 256-square plane against 0.32 ms here, with no
/// dependence on the stride at all (64x1024 and 1024x64 read the same as
/// 256x256), so the cost was the per-pixel machinery and not the memory
/// traffic. Each pixel is still the centre term plus the folded pairs in the
/// same order, so the plane stays bit for bit the reference's.
fn blur_plane(values: &[f64], width: usize, height: usize, sigma: f64, truncate: f64) -> Vec<f64> {
    let kernel = gaussian_kernel(sigma, truncate);
    let across = windows(&kernel, width);
    let down = windows(&kernel, height);

    let mut horizontal = vec![0.0f64; width * height];

    for row in 0..height {
        let line = &values[row * width..(row + 1) * width];

        for column in 0..width {
            horizontal[row * width + column] = blurred(&across[column], line, 1);
        }
    }

    let mut out = vec![0.0f64; width * height];

    for (row, window) in down.iter().enumerate() {
        let dest = &mut out[row * width..(row + 1) * width];
        let middle = &horizontal[window.middle * width..];

        for column in 0..width {
            dest[column] = window.middle_weight * middle[column];
        }

        for (left, right, weight) in &window.pairs {
            let left = &horizontal[left * width..];
            let right = &horizontal[right * width..];

            for column in 0..width {
                dest[column] += weight * (left[column] + right[column]);
            }
        }
    }

    out
}

/// A plane resampled with the cubic: the body of `enlarge_cubic/5`.
fn cubic_resize(values: &[f64], source_width: usize, source_height: usize, width: usize, height: usize) -> Vec<f64> {
    let vertical: Vec<([usize; 4], [f64; 4])> = (0..height)
        .map(|row| cubic_taps(row, height, source_height))
        .collect();
    let horizontal: Vec<([usize; 4], [f64; 4])> = (0..width)
        .map(|column| cubic_taps(column, width, source_width))
        .collect();

    let mut out = vec![0.0f64; width * height];

    for row in 0..height {
        let (offsets_y, weights_y) = vertical[row];

        for column in 0..width {
            let (offsets_x, weights_x) = horizontal[column];

            out[row * width + column] =
                weighted(values, source_width, &offsets_x, &weights_x, &offsets_y, &weights_y);
        }
    }

    out
}

/// The source a destination pixel covers along one axis: `first..last` with the
/// fraction of each end pixel, exactly as `Images.span/3` answers it.
struct Span {
    first: i64,
    last: i64,
    low: f64,
    high: f64,
}

fn span(index: usize, destination: usize, source: usize) -> Span {
    let low = index as f64 * source as f64 / destination as f64;
    let high = (index + 1) as f64 * source as f64 / destination as f64;

    Span {
        first: low.floor() as i64,
        last: high.ceil() as i64 - 1,
        low,
        high,
    }
}

fn coverage(index: i64, span: &Span) -> f64 {
    if span.first == span.last {
        span.high - span.low
    } else if index == span.first {
        span.first as f64 + 1.0 - span.low
    } else if index == span.last {
        span.high - span.last as f64
    } else {
        1.0
    }
}

/// A plane resampled by `:area`: each destination pixel averages the source it
/// covers, weighted by how much of each source pixel that is — the body of
/// `Images.by_area/3`, accumulating in the same order.
fn area_resize(values: &[f64], source_width: usize, source_height: usize, width: usize, height: usize) -> Vec<f64> {
    let vertical: Vec<Span> = (0..height).map(|row| span(row, height, source_height)).collect();
    let horizontal: Vec<Span> = (0..width).map(|column| span(column, width, source_width)).collect();

    let mut out = vec![0.0f64; width * height];

    for row in 0..height {
        let down = &vertical[row];

        for column in 0..width {
            let across = &horizontal[column];
            let mut weighted_total = 0.0f64;
            let mut weights = 0.0f64;

            for source_row in down.first..=down.last {
                for source_column in across.first..=across.last {
                    let weight = coverage(source_row, down) * coverage(source_column, across);

                    weighted_total +=
                        values[source_row as usize * source_width + source_column as usize] * weight;
                    weights += weight;
                }
            }

            out[row * width + column] = weighted_total / weights;
        }
    }

    out
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
    let values = blur_plane(&pixels, width, height, sigma, truncate);

    let mut binary = NewBinary::new(env, values.len() * std::mem::size_of::<f64>());
    let out = binary.as_mut_slice();

    for (index, value) in values.iter().enumerate() {
        let offset = index * std::mem::size_of::<f64>();
        out[offset..offset + std::mem::size_of::<f64>()].copy_from_slice(&value.to_le_bytes());
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
fn connected_labels(label_of: &[u32], width: usize, height: usize, min_size: usize, max_size: usize) -> Vec<i64> {
    let size = width * height;

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

    connected
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

/// A pyramid collapsed into one plane: every plane enlarged to `width` by
/// `height` with the cubic above, then averaged pixel by pixel in plane order.
///
/// `Pyramids.collapse_mean_reference/1` is the reference — `Pyramid.flat/1`
/// order, `Images.resize/3` with `:cubic` (no resize where the plane already
/// has the target's shape), and `Enum.sum(values) / length(values)` per pixel.
/// A channel collapses twenty-seven planes, three colour channels collapse one
/// each, and every plane crossing the boundary on its own was 24 encodings of
/// 65 536 floats a channel — most of the cost. One binary in, one plane out.
///
/// `shapes` is one `{width, height}` pair of little-endian `u32`s per plane, in
/// the same order as the planes in `planes`.
#[rustler::nif(schedule = "DirtyCpu")]
fn collapse_mean<'a>(
    env: Env<'a>,
    planes: Binary,
    shapes: Binary,
    width: usize,
    height: usize,
) -> Result<Term<'a>, rustler::Error> {
    let shapes = shapes.as_slice();

    if shapes.len() % (2 * std::mem::size_of::<u32>()) != 0 {
        return Err(rustler::Error::BadArg);
    }

    let sizes: Vec<(usize, usize)> = shapes
        .chunks_exact(2 * std::mem::size_of::<u32>())
        .map(|pair| {
            let (first, second) = pair.split_at(std::mem::size_of::<u32>());

            (
                u32::from_le_bytes(first.try_into().expect("four bytes")) as usize,
                u32::from_le_bytes(second.try_into().expect("four bytes")) as usize,
            )
        })
        .collect();

    let pixels = planes.as_slice();
    let plane_size = std::mem::size_of::<f64>();
    let mut at = 0usize;
    let mut sum = vec![0.0f64; width * height];

    for &(plane_width, plane_height) in &sizes {
        let length = plane_width * plane_height * plane_size;

        if at + length > pixels.len() {
            return Err(rustler::Error::BadArg);
        }

        let plane = &pixels[at..at + length];
        at += length;

        let values: Vec<f64> = plane
            .chunks_exact(plane_size)
            .map(|bytes| f64::from_le_bytes(bytes.try_into().expect("eight bytes")))
            .collect();

        if plane_width == width && plane_height == height {
            for (total, value) in sum.iter_mut().zip(values.iter()) {
                *total += *value;
            }
        } else {
            let vertical: Vec<([usize; 4], [f64; 4])> = (0..height)
                .map(|row| cubic_taps(row, height, plane_height))
                .collect();
            let horizontal: Vec<([usize; 4], [f64; 4])> = (0..width)
                .map(|column| cubic_taps(column, width, plane_width))
                .collect();

            for row in 0..height {
                let (offsets_y, weights_y) = vertical[row];

                for column in 0..width {
                    let (offsets_x, weights_x) = horizontal[column];
                    let sample = weighted(
                        &values,
                        plane_width,
                        &offsets_x,
                        &weights_x,
                        &offsets_y,
                        &weights_y,
                    );

                    sum[row * width + column] += sample;
                }
            }
        }
    }

    if at != pixels.len() {
        return Err(rustler::Error::BadArg);
    }

    let count = sizes.len() as f64;
    let mut binary = NewBinary::new(env, width * height * plane_size);
    let out = binary.as_mut_slice();

    for (index, total) in sum.iter().enumerate() {
        let offset = index * plane_size;
        out[offset..offset + plane_size].copy_from_slice(&(total / count).to_le_bytes());
    }

    Ok(Term::from(binary))
}

/// One colour channel's salience map, from the plane to the collapsed map.
///
/// This is `Pyramids.center_surround/2`, `Pyramid.subtract/2`,
/// `ColorChannelSalience`'s `brighter`/`darker` and mean combine, and
/// `Pyramids.collapse_mean/1` — the whole of `ColorChannelSalience.process/3`
/// except the operating-limit check — over one binary. A channel blurs
/// twenty-seven planes twice over and collapses them; each plane crossing the
/// boundary on its own was most of a cows step's second.
///
/// Every floating-point scalar is resolved on the Elixir side and handed in:
/// the octave shapes (`Pyramids.octave_shapes/2`), the sigma each further scale
/// is blurred by, and the sigma each surround is blurred by. Nothing here
/// computes a power or a square root, so the two paths cannot disagree about a
/// scalar before they have even started. The rest — the same `f64` operations in
/// the same order — is what the other kernels already answer bit for bit.
///
/// Answers `{map, centres, centre_shapes}`: the collapsed map at the finest
/// octave's shape, the centre pyramid's planes concatenated, and one
/// `{width, height}` pair of `u32`s per centre plane.
#[rustler::nif(schedule = "DirtyCpu")]
fn channel_salience<'a>(
    env: Env<'a>,
    plane: Binary,
    shapes: Binary,
    first_sigma: f64,
    scale_sigmas: Binary,
    surround_sigmas: Binary,
    truncate: f64,
) -> Result<Term<'a>, rustler::Error> {
    let shapes = pairs_of_u32(shapes.as_slice())?;
    let scale_sigmas = f64s(scale_sigmas.as_slice())?;
    let surround_sigmas = f64s(surround_sigmas.as_slice())?;

    if shapes.is_empty() || scale_sigmas.is_empty() || scale_sigmas.len() != surround_sigmas.len() {
        return Err(rustler::Error::BadArg);
    }

    let (width, height) = shapes[0];
    let image = decode(plane.as_slice(), width * height)?;
    let scales = scale_sigmas.len();

    // The centre pyramid, octave by octave: three planes each here, the last of
    // which the next octave starts from.
    let mut centre: Vec<(usize, usize, Vec<f64>)> = Vec::new();
    let mut extra: Option<Vec<f64>> = None;
    let mut extra_shape = (width, height);

    for &(w, h) in &shapes {
        let first = match &extra {
            None => blur_plane(&image, width, height, first_sigma, truncate),
            Some(previous) => area_resize(previous, extra_shape.0, extra_shape.1, w, h),
        };

        let mut previous = first.clone();
        centre.push((w, h, first));

        for (index, &sigma) in scale_sigmas.iter().enumerate() {
            previous = blur_plane(&previous, w, h, sigma, truncate);

            // `Enum.take(planes, scales)` keeps the first `scales` planes; the
            // one built last is what the next octave starts from, not a plane
            // the pyramid holds.
            if index + 1 < scales {
                centre.push((w, h, previous.clone()));
            }
        }

        extra = Some(previous);
        extra_shape = (w, h);
    }

    // The surround, and the difference: same order, plane by plane.
    let mut combined: Vec<(usize, usize, Vec<f64>)> = Vec::with_capacity(centre.len());

    for (index, (w, h, centre_plane)) in centre.iter().enumerate() {
        let scale = index % scales;
        let surround = blur_plane(centre_plane, *w, *h, surround_sigmas[scale], truncate);

        let mut brighter = Vec::with_capacity(centre_plane.len());
        let mut darker = Vec::with_capacity(centre_plane.len());

        for (left, right) in centre_plane.iter().zip(surround.iter()) {
            // `Pyramid.subtract/2` is `left + -1.0 * right`, not `left - right`.
            let difference = left + -1.0 * right;

            brighter.push(difference.max(0.0));
            darker.push((-difference).max(0.0));
        }

        // `combine_mean` of the two: the sum in pyramid order, over two.
        combined.push((
            *w,
            *h,
            brighter
                .iter()
                .zip(darker.iter())
                .map(|(up, down)| (up + down) / 2.0)
                .collect(),
        ));
    }

    // The collapse: every plane at the finest shape, averaged in plane order.
    let mut sum = vec![0.0f64; width * height];

    for (w, h, values) in &combined {
        if *w == width && *h == height {
            for (total, value) in sum.iter_mut().zip(values.iter()) {
                *total += *value;
            }
        } else {
            let enlarged = cubic_resize(values, *w, *h, width, height);

            for (total, value) in sum.iter_mut().zip(enlarged.iter()) {
                *total += *value;
            }
        }
    }

    let count = combined.len() as f64;
    let mut map = NewBinary::new(env, width * height * std::mem::size_of::<f64>());

    for (index, total) in sum.iter().enumerate() {
        let offset = index * std::mem::size_of::<f64>();
        map.as_mut_slice()[offset..offset + std::mem::size_of::<f64>()]
            .copy_from_slice(&(total / count).to_le_bytes());
    }

    let mut planes = NewBinary::new(env, centre.iter().map(|(w, h, _)| w * h).sum::<usize>() * std::mem::size_of::<f64>());
    let mut at = 0usize;

    for (_w, _h, values) in &centre {
        for value in values {
            let offset = at;
            planes.as_mut_slice()[offset..offset + std::mem::size_of::<f64>()]
                .copy_from_slice(&value.to_le_bytes());
            at += std::mem::size_of::<f64>();
        }
    }

    let mut centre_shapes = NewBinary::new(env, centre.len() * 2 * std::mem::size_of::<u32>());

    for (index, (w, h, _values)) in centre.iter().enumerate() {
        let offset = index * 2 * std::mem::size_of::<u32>();
        centre_shapes.as_mut_slice()[offset..offset + 4].copy_from_slice(&(*w as u32).to_le_bytes());
        centre_shapes.as_mut_slice()[offset + 4..offset + 8].copy_from_slice(&(*h as u32).to_le_bytes());
    }

    let answer: (Binary, Binary, Binary) = (map.into(), planes.into(), centre_shapes.into());

    Ok(answer.encode(env))
}

fn pairs_of_u32(bytes: &[u8]) -> Result<Vec<(usize, usize)>, rustler::Error> {
    if bytes.len() % (2 * std::mem::size_of::<u32>()) != 0 {
        return Err(rustler::Error::BadArg);
    }

    Ok(bytes
        .chunks_exact(2 * std::mem::size_of::<u32>())
        .map(|pair| {
            let (first, second) = pair.split_at(std::mem::size_of::<u32>());

            (
                u32::from_le_bytes(first.try_into().expect("four bytes")) as usize,
                u32::from_le_bytes(second.try_into().expect("four bytes")) as usize,
            )
        })
        .collect())
}

fn f64s(bytes: &[u8]) -> Result<Vec<f64>, rustler::Error> {
    if bytes.len() % std::mem::size_of::<f64>() != 0 {
        return Err(rustler::Error::BadArg);
    }

    Ok(bytes
        .chunks_exact(std::mem::size_of::<f64>())
        .map(|value| f64::from_le_bytes(value.try_into().expect("eight bytes")))
        .collect())
}

/// The feature maps combined and normalised: the last step of a VOCUS2 map.
///
/// `Vocus2.combine_weighted_reference/2` and `Vocus2.range_normalize/1` are the
/// reference. The weighted mean is `WeightedMean.call/2` — each map scaled by
/// its weight over the total, then summed in map order starting from `0.0`, so
/// the addition order is the same as `Enum.sum/1`'s — and the normalisation is
/// `range_normalize/1`: `(value - low) / range`, or a clip to `[0, 1]` when the
/// range is smaller than `1.0e-8`.
///
/// `maps` is `count` planes of `width * height` little-endian `f64` values,
/// concatenated; `weights` is one little-endian `f64` per map.
#[rustler::nif(schedule = "DirtyCpu")]
fn combine_weighted<'a>(
    env: Env<'a>,
    maps: Binary,
    weights: Binary,
    width: usize,
    height: usize,
) -> Result<Term<'a>, rustler::Error> {
    let weights = f64s(weights.as_slice())?;
    let values = f64s(maps.as_slice())?;
    let size = width * height;

    if weights.is_empty() || values.len() != weights.len() * size {
        return Err(rustler::Error::BadArg);
    }

    let total = weights.iter().fold(0.0f64, |sum, weight| sum + weight.abs());

    if total == 0.0 {
        return Err(rustler::Error::BadArg);
    }

    let scaled: Vec<f64> = weights.iter().map(|weight| weight / total).collect();
    let mut out = vec![0.0f64; size];

    for (map, weight) in scaled.iter().enumerate() {
        let plane = &values[map * size..(map + 1) * size];

        for (index, value) in plane.iter().enumerate() {
            out[index] += weight * value;
        }
    }

    let mut low = out[0];
    let mut high = out[0];

    for value in &out {
        if *value < low {
            low = *value;
        }

        if *value > high {
            high = *value;
        }
    }

    let range = high - low;
    let tiny = range.abs() <= 1.0e-8;

    let mut binary = NewBinary::new(env, size * std::mem::size_of::<f64>());
    let bytes = binary.as_mut_slice();

    for (index, value) in out.iter().enumerate() {
        let normalised = if tiny {
            value.max(0.0).min(1.0)
        } else {
            (value - low) / range
        };

        let offset = index * std::mem::size_of::<f64>();
        bytes[offset..offset + std::mem::size_of::<f64>()].copy_from_slice(&normalised.to_le_bytes());
    }

    Ok(Term::from(binary))
}

/// sRGB to the Lab `skimage` answers, three planes out of one interleaved binary.
///
/// `Images.rgb_to_lab/1` and `SlicMerge.skimage_lab/1` are the reference: the
/// rescale `(value - low) / span * 255.0`, the gamma decode, OpenCV's D65
/// matrix, the white point, `lab_f`, the 8-bit scaling with its clamps, and the
/// `L * 100`, `a * 255 - 128`, `b * 255 - 128` the wrapper reads back. `rgb` is
/// `count` pixels of three little-endian `f64`s, row-major; the answer is three
/// planes of `count` values, concatenated `L`, `a`, `b`.
#[rustler::nif(schedule = "DirtyCpu")]
fn lab<'a>(
    env: Env<'a>,
    rgb: Binary,
    count: usize,
    low: f64,
    span: f64,
) -> Result<Term<'a>, rustler::Error> {
    encode_planes(env, lab_values(rgb.as_slice(), count, low, span)?, count, true)
}

/// The mean colour of every superpixel, in the scale Monty's merge threshold is
/// a threshold in — `cv2.cvtColor(image, COLOR_RGB2LAB) / 255`, averaged per
/// region.
///
/// `SlicMerge.compute_superpixel_mean_colors/2` is the reference. The conversion
/// already had a kernel and the mean did not: 65 536 `Map` updates, over a pixel
/// list woven out of the three planes first, and the crossing to get the planes
/// at all. This is the same sum in raster order, per region, in one crossing —
/// the planes in, one colour per region out, and a region the labels never name
/// answers the zeros the reference leaves.
///
/// `rgb` is `width * height` pixels of three little-endian `f64`s; `labels` is
/// one `u32` per pixel; the answer is three `f64` per region, `region_max + 1`
/// regions, in label order.
#[rustler::nif(schedule = "DirtyCpu")]
fn region_colours<'a>(
    env: Env<'a>,
    rgb: Binary,
    labels: Binary,
    width: usize,
    height: usize,
) -> Result<Term<'a>, rustler::Error> {
    let count = width * height;

    if count == 0 || labels.as_slice().len() != count * std::mem::size_of::<u32>() {
        return Err(rustler::Error::BadArg);
    }

    let label_of: Vec<u32> = labels
        .as_slice()
        .chunks_exact(std::mem::size_of::<u32>())
        .map(|bytes| u32::from_le_bytes(bytes.try_into().expect("four bytes")))
        .collect();

    // This call converts the camera's own values, so the rescale is the identity
    // — `low: 0.0, span: 255.0`.
    let planes = lab_values(rgb.as_slice(), count, 0.0, 255.0)?;

    let regions = label_of.iter().copied().max().map_or(1, |max| max as usize + 1);
    let mut counts = vec![0.0f64; regions];
    let mut sums = vec![[0.0f64; 3]; regions];

    for index in 0..count {
        let region = label_of[index] as usize;

        counts[region] += 1.0;
        sums[region][0] += planes[0][index];
        sums[region][1] += planes[1][index];
        sums[region][2] += planes[2][index];
    }

    let unit = std::mem::size_of::<f64>();
    let mut binary = NewBinary::new(env, regions * 3 * unit);
    let out = binary.as_mut_slice();

    for region in 0..regions {
        let colour = if counts[region] == 0.0 {
            [0.0, 0.0, 0.0]
        } else {
            [
                sums[region][0] / counts[region],
                sums[region][1] / counts[region],
                sums[region][2] / counts[region],
            ]
        };

        for (channel, value) in colour.iter().enumerate() {
            let offset = (region * 3 + channel) * unit;
            out[offset..offset + unit].copy_from_slice(&value.to_le_bytes());
        }
    }

    Ok(Term::from(binary))
}

/// The three Lab planes, in the wrapper's scaled units.
fn lab_values(bytes: &[u8], count: usize, low: f64, span: f64) -> Result<Vec<Vec<f64>>, rustler::Error> {
    let values = f64s(bytes)?;

    if values.len() != count * 3 {
        return Err(rustler::Error::BadArg);
    }

    let mut lightness = vec![0.0f64; count];
    let mut a_plane = vec![0.0f64; count];
    let mut b_plane = vec![0.0f64; count];

    for index in 0..count {
        let red = (values[index * 3] - low) / span * 255.0;
        let green = (values[index * 3 + 1] - low) / span * 255.0;
        let blue = (values[index * 3 + 2] - low) / span * 255.0;

        let red = gamma_decode(red / 255.0);
        let green = gamma_decode(green / 255.0);
        let blue = gamma_decode(blue / 255.0);

        let x = 0.412453 * red + 0.357580 * green + 0.180423 * blue;
        let y = 0.212671 * red + 0.715160 * green + 0.072169 * blue;
        let z = 0.019334 * red + 0.119193 * green + 0.950227 * blue;

        let f_x = lab_f(x / WHITE[0]);
        let f_y = lab_f(y / WHITE[1]);
        let f_z = lab_f(z / WHITE[2]);

        lightness[index] = clip(255.0 * (116.0 * f_y - 16.0) / 100.0, 0.0, 255.0) / 255.0;
        a_plane[index] = clip(500.0 * (f_x - f_y) + 128.0, 0.0, 255.0) / 255.0;
        b_plane[index] = clip(200.0 * (f_y - f_z) + 128.0, 0.0, 255.0) / 255.0;
    }

    Ok(vec![lightness, a_plane, b_plane])
}

/// The three planes as one binary, in the wrapper's units or `skimage`'s.
fn encode_planes<'a>(
    env: Env<'a>,
    planes: Vec<Vec<f64>>,
    count: usize,
    skimage: bool,
) -> Result<Term<'a>, rustler::Error> {
    let unit = std::mem::size_of::<f64>();
    let mut binary = NewBinary::new(env, count * 3 * unit);
    let out = binary.as_mut_slice();

    for (plane, values) in planes.iter().enumerate() {
        for (index, value) in values.iter().enumerate() {
            let scaled = if skimage {
                if plane == 0 {
                    value * 100.0
                } else {
                    value * 255.0 - 128.0
                }
            } else {
                *value
            };

            let offset = (plane * count + index) * unit;
            out[offset..offset + unit].copy_from_slice(&scaled.to_le_bytes());
        }
    }

    Ok(Term::from(binary))
}

/// OpenCV's white point.
const WHITE: [f64; 3] = [0.950456, 1.0, 1.088754];

fn gamma_decode(value: f64) -> f64 {
    if value <= 0.04045 {
        value / 12.92
    } else {
        ((value + 0.055) / 1.055).powf(2.4)
    }
}

fn lab_f(value: f64) -> f64 {
    if value > 0.008856 {
        value.powf(1.0 / 3.0)
    } else {
        7.787 * value + 16.0 / 116.0
    }
}

fn clip(value: f64, low: f64, high: f64) -> f64 {
    value.max(low).min(high)
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
/// The scalar side of `slic/3`: Monty's own SLIC parameters, and the seed grid
/// the Elixir side has already worked out — `SlicMerge.grid_centroids/2` is
/// `skimage`'s `regular_grid`, and it is twenty numbers, not sixty-five
/// thousand, so it does not belong behind the boundary.
#[derive(rustler::NifMap)]
struct SlicSettings {
    width: usize,
    height: usize,
    step_y: i64,
    step_x: i64,
    spatial_factor: f64,
    compactness: f64,
    max_iter: usize,
    sigma: f64,
    truncate: f64,
    min_size: usize,
    max_size: usize,
}

/// `skimage.segmentation.slic`, which is one call in Monty's `slic_merge.py` and
/// the whole of the label field: the rescale that fills `[0, 1]`, the Lab
/// conversion, the Gaussian of `sigma`, the k-means in Lab-plus-position space,
/// and the connectivity pass.
///
/// Every stage in that chain already had a kernel, and each crossing between two
/// of them cost more than the arithmetic it carried: three 256-square blurs
/// measured 29.15 ms through their own crossing against 0.96 ms of taps, and
/// interleaving three planes into the k-means's binary another 8.75 ms. This is
/// the same chain with no crossings and the same numbers — the same
/// `lab_values`, the same `blur_plane`, the same `k_means`, the same
/// `connected_labels` — so the label field is the one `segment_image_reference/2`
/// answers, bit for bit, which its parity case holds it to on several shapes.
///
/// `rgb` is `width * height` pixels of three little-endian `f64`s; `seeds` is
/// five `f64` each (`y`, `x`, `r`, `g`, `b`); the answer is one little-endian
/// `u32` per pixel.
#[rustler::nif(schedule = "DirtyCpu")]
fn slic<'a>(
    env: Env<'a>,
    rgb: Binary,
    seeds: Binary,
    settings: SlicSettings,
) -> Result<Term<'a>, rustler::Error> {
    let count = settings.width * settings.height;

    if count == 0 || rgb.as_slice().len() != count * 3 * std::mem::size_of::<f64>() {
        return Err(rustler::Error::BadArg);
    }

    // `img_as_float` and the wrapper's rescale: the colours stretched to fill
    // their own range, which is what makes `compactness` mean the same thing on
    // any camera. The scale is the whole image's, so it is found first.
    let values = f64s(rgb.as_slice())?;
    let mut low = f64::INFINITY;
    let mut high = f64::NEG_INFINITY;

    for value in &values {
        low = low.min(*value);
        high = high.max(*value);
    }

    let span = if high == low { 1.0 } else { high - low };

    // `rgb2lab`, in `skimage`'s units: `L` in `0..100`, `a` and `b` unshifted.
    let planes: Vec<Vec<f64>> = lab_values(rgb.as_slice(), count, low, span)?
        .into_iter()
        .enumerate()
        .map(|(plane, values)| {
            values
                .into_iter()
                .map(|value| if plane == 0 { value * 100.0 } else { value * 255.0 - 128.0 })
                .collect()
        })
        .collect();

    // `gaussian(image, sigma=[sigma, sigma, 0], mode="reflect")`: each channel on
    // its own, so no colour bleeds into another.
    let smoothed: Vec<Vec<f64>> = if settings.sigma > 0.0 {
        planes
            .iter()
            .map(|plane| {
                blur_plane(plane, settings.width, settings.height, settings.sigma, settings.truncate)
            })
            .collect()
    } else {
        planes
    };

    let factor = 1.0 / settings.compactness;
    let mut points = vec![0.0f64; count * 3];

    for index in 0..count {
        points[index * 3] = smoothed[0][index] * factor;
        points[index * 3 + 1] = smoothed[1][index] * factor;
        points[index * 3 + 2] = smoothed[2][index] * factor;
    }

    let mut centres = seeds_of(seeds.as_slice())?;

    let labels = k_means(
        &points,
        settings.width,
        settings.height,
        &mut centres,
        settings.step_y,
        settings.step_x,
        settings.spatial_factor,
        settings.max_iter,
    );

    let connected = connected_labels(
        &labels,
        settings.width,
        settings.height,
        settings.min_size,
        settings.max_size,
    );

    let mut binary = NewBinary::new(env, count * std::mem::size_of::<u32>());
    let out = binary.as_mut_slice();

    for (index, label) in connected.iter().enumerate() {
        let offset = index * std::mem::size_of::<u32>();
        out[offset..offset + std::mem::size_of::<u32>()].copy_from_slice(&(*label as u32).to_le_bytes());
    }

    Ok(Term::from(binary))
}

/// One centroid as the binary carries it: five little-endian `f64`s.
fn seed_of(chunk: &[u8]) -> Seed {
    let mut numbers = [0.0f64; 5];

    for (slot, bytes) in chunk.chunks_exact(std::mem::size_of::<f64>()).enumerate() {
        numbers[slot] = f64::from_le_bytes(bytes.try_into().expect("eight bytes"));
    }

    Seed {
        y: numbers[0],
        x: numbers[1],
        colour: [numbers[2], numbers[3], numbers[4]],
        dead: false,
    }
}

fn seeds_of(bytes: &[u8]) -> Result<Vec<Seed>, rustler::Error> {
    let bytes_per_seed = 5 * std::mem::size_of::<f64>();

    if bytes.len() % bytes_per_seed != 0 {
        return Err(rustler::Error::BadArg);
    }

    Ok(bytes.chunks_exact(bytes_per_seed).map(seed_of).collect())
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
