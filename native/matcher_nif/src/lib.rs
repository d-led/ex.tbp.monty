//! The arithmetic a matching step repeats once per node and once per hypothesis.
//!
//! Two questions, asked of the same graphs on every step of every episode:
//!
//! * **feature evidence** — how well do the observation's features match each
//!   stored node's? (`feature_evidence`)
//! * **neighbour evidence** — where a hypothesis says the sensor is, which of
//!   the nodes around that place matches the sensed pose best? (`neighbour_evidence`)
//!
//! In Elixir each costs a hundred-odd words per answer — tuples of columns, lists
//! of values, boxed floats — which came to a large part of a step's garbage for
//! arithmetic that is a few multiplications and a division. These are the same
//! arithmetic as loops over flat binaries.
//!
//! ## Why the rows are binaries
//!
//! The rows do not change while an episode is being matched: they are written
//! when a graph gains nodes, which is the end of a *training* episode. So they
//! are flattened once, when they are built, and every step reads the same bytes.
//!
//! A `nil` in a row is a feature that node does not have — Monty's NaN. It is
//! written as a NaN here and read back as `nil`, which is why the answer for
//! such a node is a NaN too: no evidence rather than zero evidence.
//!
//! ## What these are held to
//!
//! The Elixir modules stay the reference and stay runnable:
//! `DefaultFeatureEvidenceCalculator` for the first kernel, and
//! `HypothesesDisplacer.neighbour_evidence/5` (with the pose arithmetic around
//! it) for the second. Parity tests compare the answers exactly, and a caller
//! only takes the native path when the answers can be the same ones.

use rustler::{Binary, Env, NewBinary};

/// A column of a row, as the calculator describes it: which value of the row it
/// reads, and what kind of comparison applies.
const KIND_NUMERIC: u32 = 0;
const KIND_CIRCULAR: u32 = 1;

/// The range a circular feature wraps over. Monty's hues go round once.
const CIRCULAR_RANGE: f64 = 1.0;

/// What the index writes where a query found fewer neighbours than it asked for.
const NO_NEIGHBOUR: u32 = u32::MAX;

/// A quarter turn, in radians: the fold that makes a curvature direction
/// signless and everything else worse.
const HALF_TURN: f64 = std::f64::consts::FRAC_PI_2;

/// Always true, from the native side: the only way to know this library loaded.
#[rustler::nif]
fn available() -> bool {
    true
}

/// The feature evidence of every row, in the rows' own order.
///
/// * `rows` — `n * width` little-endian f64, one row after another, NaN where a
///   node has no value for a feature.
/// * `width` — how many values make one row.
/// * `specs` — per column, two u32: the index of the row value it reads, and its
///   kind (`0` numeric, `1` circular, `2` categorical).
/// * `params` — per column, three f64: the observed value, its tolerance, and
///   its weight.
/// * `increment` — Monty's scale for feature evidence against pose evidence.
///
/// The answer is `n` little-endian f64: the weighted mean of the columns'
/// evidence, or NaN for a node that is missing one of the values, or whose
/// columns weigh nothing.
#[rustler::nif]
fn feature_evidence<'a>(
    env: Env<'a>,
    rows: Binary,
    width: u32,
    specs: Binary,
    params: Binary,
    increment: f64,
) -> Binary<'a> {
    let width = width as usize;
    let count = rows.len().checked_div(width.saturating_mul(8)).unwrap_or(0);
    let columns = columns(specs.as_slice(), params.as_slice());

    let mut output = NewBinary::new(env, count * 8);

    for index in 0..count {
        let evidence = row_evidence(
            rows.as_slice(),
            index * width * 8,
            width,
            &columns,
            increment,
        );

        write_f64(&mut output, index, evidence);
    }

    output.into()
}

/// The best evidence around each hypothesis, given where it says the sensor is.
///
/// * `ids` — `m * k` little-endian u32: for each hypothesis, the graph nodes
///   nearest its search location, as the index answered them (`u32::MAX` where
///   there was no neighbour that far out).
/// * `k` — how many ids belong to one hypothesis.
/// * `hypotheses` — what was asked: `[queries, poses, sensed]`, being the
///   search locations (`m * 3` f64), each hypothesis' rotation (`m * 9` f64, row
///   by row) and the observation's own surface normal and first curvature
///   direction (6 f64, unturned). Grouped because they travel together.
/// * `graph` — what was asked of: `[nodes, node_pose, node_defined,
///   node_value]`, being every node's location (`n * 3` f64), its normal and
///   first curvature direction (`n * 6` f64), whether its pose was fully defined
///   (`n` f64, `0.0` for not) and what its features were worth (`n` f64).
/// * `params` — 6 f64: `flatness`, `max_match_distance`, the normal weight, the
///   curvature weight, whether the observation defined a curvature direction
///   (`1.0` or `0.0`), and the evidence of a hypothesis with no neighbour in
///   range.
///
/// The answer is `m` little-endian f64: the best evidence among each
/// hypothesis' neighbours, or `params[5]` when it has none. A caller that hands
/// over the wrong number of arrays gets no answers rather than a crash: a panic
/// would take the whole VM with it.
#[rustler::nif]
fn neighbour_evidence<'a>(
    env: Env<'a>,
    ids: Binary,
    k: u32,
    hypotheses: Vec<Binary>,
    graph: Vec<Binary>,
    params: Binary,
) -> Binary<'a> {
    let k = k as usize;
    let hypotheses_count = ids.len().checked_div(k.saturating_mul(4)).unwrap_or(0);
    let mut output = NewBinary::new(env, hypotheses_count * 8);

    let asked: Result<[Binary; 3], _> = hypotheses.try_into();
    let known: Result<[Binary; 4], _> = graph.try_into();

    let (Ok([queries, poses, sensed]), Ok([nodes, node_pose, node_defined, node_value])) =
        (asked, known)
    else {
        return output.into();
    };

    let settings = Settings::read(params.as_slice());
    let sensed = [
        f64_at(sensed.as_slice(), 0),
        f64_at(sensed.as_slice(), 8),
        f64_at(sensed.as_slice(), 16),
        f64_at(sensed.as_slice(), 24),
        f64_at(sensed.as_slice(), 32),
        f64_at(sensed.as_slice(), 40),
    ];

    for hypothesis in 0..hypotheses_count {
        let evidence = best_neighbour(
            &ids.as_slice()[hypothesis * k * 4..(hypothesis + 1) * k * 4],
            hypothesis,
            &queries,
            &poses,
            &sensed,
            &nodes,
            &node_pose,
            &node_defined,
            &node_value,
            &settings,
        );

        write_f64(&mut output, hypothesis, evidence);
    }

    output.into()
}

/// The six numbers a neighbour comparison reads, in the order they arrive.
struct Settings {
    flatness: f64,
    max_match_distance: f64,
    normal_weight: f64,
    curvature_weight: f64,
    fully_defined: bool,
    min_evidence: f64,
}

impl Settings {
    fn read(bytes: &[u8]) -> Settings {
        Settings {
            flatness: f64_at(bytes, 0),
            max_match_distance: f64_at(bytes, 8),
            normal_weight: f64_at(bytes, 16),
            curvature_weight: f64_at(bytes, 24),
            fully_defined: f64_at(bytes, 32) != 0.0,
            min_evidence: f64_at(bytes, 40),
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn best_neighbour(
    ids: &[u8],
    hypothesis: usize,
    queries: &Binary,
    poses: &Binary,
    sensed: &[f64; 6],
    nodes: &Binary,
    node_pose: &Binary,
    node_defined: &Binary,
    node_value: &Binary,
    settings: &Settings,
) -> f64 {
    let [normal, curvature] = turned(&poses.as_slice()[hypothesis * 72..], sensed);
    let query = &queries.as_slice()[hypothesis * 24..];

    let mut best = f64::NEG_INFINITY;

    for slot in 0..ids.len() / 4 {
        let id = u32_at(ids, slot * 4);

        if id == NO_NEIGHBOUR {
            continue;
        }

        let id = id as usize;

        let evidence = if in_range(nodes, id, query, &normal, settings) {
            pose_evidence(node_pose, node_defined, id, &normal, &curvature, settings)
                + f64_at(node_value.as_slice(), id * 8)
        } else {
            // A neighbour beyond `max_match_distance` is no neighbour at all: it
            // says the sensor's location has nothing to do with this hypothesis,
            // which is the worst evidence there is.
            settings.min_evidence
        };

        best = best.max(evidence);
    }

    if best == f64::NEG_INFINITY {
        settings.min_evidence
    } else {
        best
    }
}

/// The sensed normal and curvature direction turned by one hypothesis' pose.
///
/// Monty stores a frame as three rows, so turning a vector is one matrix times
/// one vector. The same products in the same order as
/// `rotate_normal_and_curvature/2`, so the same floats.
fn turned(pose: &[u8], sensed: &[f64; 6]) -> [[f64; 3]; 2] {
    let [n1, n2, n3, d1, d2, d3] = *sensed;

    let rows = [
        [f64_at(pose, 0), f64_at(pose, 8), f64_at(pose, 16)],
        [f64_at(pose, 24), f64_at(pose, 32), f64_at(pose, 40)],
        [f64_at(pose, 48), f64_at(pose, 56), f64_at(pose, 64)],
    ];

    let turn = |x: f64, y: f64, z: f64| {
        [
            rows[0][0] * x + rows[0][1] * y + rows[0][2] * z,
            rows[1][0] * x + rows[1][1] * y + rows[1][2] * z,
            rows[2][0] * x + rows[2][1] * y + rows[2][2] * z,
        ]
    };

    [turn(n1, n2, n3), turn(d1, d2, d3)]
}

/// How far off its tangent plane the sensed surface lets a search stray.
fn in_range(
    nodes: &Binary,
    id: usize,
    query: &[u8],
    normal: &[f64; 3],
    settings: &Settings,
) -> bool {
    let distance = custom_distance(nodes.as_slice(), id, query, normal, settings.flatness);

    (settings.max_match_distance - distance) / settings.max_match_distance > 0.0
}

/// The distance from one search point to one node, flattened along the normal.
///
/// A plain Euclidean distance treats the search sphere as a ball; the surface a
/// sensor is looking at is not one. Adding `|dot(difference, normal)|` penalises
/// candidates that sit off the sensed tangent plane, and `flatness` scales that
/// penalty by the curvature.
fn custom_distance(nodes: &[u8], id: usize, query: &[u8], normal: &[f64; 3], flatness: f64) -> f64 {
    let difference = [
        f64_at(nodes, id * 24) - f64_at(query, 0),
        f64_at(nodes, id * 24 + 8) - f64_at(query, 8),
        f64_at(nodes, id * 24 + 16) - f64_at(query, 16),
    ];

    let magnitude = (difference[0] * difference[0]
        + difference[1] * difference[1]
        + difference[2] * difference[2])
        .sqrt();

    let along = difference[0] * normal[0] + difference[1] * normal[1] + difference[2] * normal[2];

    magnitude + along.abs() * flatness
}

/// Pose evidence in `[-1, 1]`: surface normal and first curvature direction,
/// each worth `0.5` when they match and `-0.5` when perpendicular.
fn pose_evidence(
    node_pose: &Binary,
    node_defined: &Binary,
    id: usize,
    normal: &[f64; 3],
    curvature: &[f64; 3],
    settings: &Settings,
) -> f64 {
    let stored_normal = [
        f64_at(node_pose.as_slice(), id * 48),
        f64_at(node_pose.as_slice(), id * 48 + 8),
        f64_at(node_pose.as_slice(), id * 48 + 16),
    ];

    let normal_evidence = -((angle(&stored_normal, normal) / 2.0).sin() - 0.5);

    let curvature_evidence = if settings.fully_defined {
        let stored_curvature = [
            f64_at(node_pose.as_slice(), id * 48 + 24),
            f64_at(node_pose.as_slice(), id * 48 + 32),
            f64_at(node_pose.as_slice(), id * 48 + 40),
        ];

        // A curvature direction has no sign, so 0° and 180° are equally good and
        // 90° is the worst case: that is what folding the angle at π/2 does.
        let error = HALF_TURN - (angle(&stored_curvature, curvature) - HALF_TURN).abs();
        let defined = if f64_at(node_defined.as_slice(), id * 8) != 0.0 {
            1.0
        } else {
            0.0
        };

        -(error.sin() - 0.5) * defined
    } else {
        0.0
    };

    normal_evidence * settings.normal_weight + curvature_evidence * settings.curvature_weight
}

/// The angle Monty reads off two pose directions, straight from the dot product
/// and clipped at ±1, with no normalisation — the lengths are part of the
/// comparison (see `SpatialArithmetics.get_angle/2`).
///
/// Two comparisons rather than `clamp`, because two comparisons are what the
/// reference does (`clip/3`), and a cosine that arrives as a NaN should stay one
/// rather than reach an `acos` that treats it as an argument error.
#[allow(clippy::manual_clamp)]
fn angle(a: &[f64; 3], b: &[f64; 3]) -> f64 {
    let dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

    dot.max(-1.0).min(1.0).acos()
}

/// One column: where to read it, how to compare it, and what it is worth.
struct Column {
    index: usize,
    kind: u32,
    value: f64,
    tolerance: f64,
    weight: f64,
}

fn columns(specs: &[u8], params: &[u8]) -> Vec<Column> {
    let count = specs.len() / 8;

    (0..count)
        .map(|column| Column {
            index: u32_at(specs, column * 8) as usize,
            kind: u32_at(specs, column * 8 + 4),
            value: f64_at(params, column * 24),
            tolerance: f64_at(params, column * 24 + 8),
            weight: f64_at(params, column * 24 + 16),
        })
        .collect()
}

fn row_evidence(rows: &[u8], base: usize, width: usize, columns: &[Column], increment: f64) -> f64 {
    if columns.is_empty() {
        return f64::NAN;
    }

    let mut total_weight = 0.0;
    let mut weighted = 0.0;

    for column in columns {
        if column.index >= width {
            return f64::NAN;
        }

        let value = f64_at(rows, base + column.index * 8);

        if value.is_nan() {
            return f64::NAN;
        }

        total_weight += column.weight;
        weighted += column.weight * column_evidence(column, value);
    }

    if total_weight == 0.0 {
        f64::NAN
    } else {
        weighted / total_weight * increment
    }
}

/// How far inside its tolerance a value sits: no difference is `1`, a difference
/// at the tolerance is `0`, and it falls off linearly in between.
fn column_evidence(column: &Column, value: f64) -> f64 {
    let difference = difference(column, value);

    if column.tolerance == 0.0 {
        // The limit of the falloff below: only an exact match has evidence.
        if difference == 0.0 {
            1.0
        } else {
            0.0
        }
    } else {
        (column.tolerance - difference).max(0.0) / column.tolerance
    }
}

fn difference(column: &Column, value: f64) -> f64 {
    match column.kind {
        KIND_CIRCULAR => {
            // The short way round, so a hue of 0.99 and one of 0.01 are
            // neighbours rather than 0.98 apart.
            let raw = value - column.value;

            (CIRCULAR_RANGE + raw)
                .abs()
                .min(raw.abs())
                .min((value - (column.value + CIRCULAR_RANGE)).abs())
        }
        KIND_NUMERIC => (value - column.value).abs(),
        _ => {
            // Anything else is a categorical match: equal or not.
            if value == column.value {
                0.0
            } else {
                1.0
            }
        }
    }
}

fn f64_at(bytes: &[u8], offset: usize) -> f64 {
    let mut raw = [0u8; 8];
    raw.copy_from_slice(&bytes[offset..offset + 8]);
    f64::from_le_bytes(raw)
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    let mut raw = [0u8; 4];
    raw.copy_from_slice(&bytes[offset..offset + 4]);
    u32::from_le_bytes(raw)
}

fn write_f64(binary: &mut NewBinary, index: usize, value: f64) {
    binary[index * 8..(index + 1) * 8].copy_from_slice(&value.to_le_bytes());
}

// -- where a hypothesis moves to ---------------------------------------------

/// Every hypothesis' search location after the sensor moved by `displacement`.
///
/// A hypothesis says "the sensor is here, and the object is turned this way", so
/// when the sensor moves by `d` the hypothesis moves to `pose · d` away from
/// where it was. Every hypothesis is moved, not just the likely ones: dropping
/// one would lose the path information it carries.
///
/// * `poses` — `m * 9` f64, each hypothesis' rotation row by row.
/// * `locations` — `m * 3` f64, where each hypothesis says the sensor is now.
/// * `displacement` — 3 f64, how far the sensor moved, in its own frame.
///
/// The answer is `m * 3` f64: `location + pose · displacement`, row by row.
/// This is `SpatialArithmetics.add(location, Geometry.apply(pose, displacement))`
/// in Elixir — the same three dot products, in the same order, so a test can
/// hold the two answers equal rather than close.
#[rustler::nif]
fn displaced_locations<'a>(
    env: Env<'a>,
    poses: Binary,
    locations: Binary,
    displacement: Binary,
) -> Binary<'a> {
    let count = locations.len() / 24;
    let moved = [
        f64_at(displacement.as_slice(), 0),
        f64_at(displacement.as_slice(), 8),
        f64_at(displacement.as_slice(), 16),
    ];

    let mut output = NewBinary::new(env, count * 24);

    for index in 0..count {
        let pose_at = index * 72;

        for row in 0..3 {
            let row_at = pose_at + row * 24;
            let turned = f64_at(poses.as_slice(), row_at) * moved[0]
                + f64_at(poses.as_slice(), row_at + 8) * moved[1]
                + f64_at(poses.as_slice(), row_at + 16) * moved[2];

            let ahead = f64_at(locations.as_slice(), index * 24 + row * 8) + turned;

            write_f64(&mut output, index * 3 + row, ahead);
        }
    }

    output.into()
}

// -- the patch's surface -----------------------------------------------------

/// The principal curvatures at the middle of a patch, and their directions.
///
/// * `points` — `count * stride` f64, one row per pixel: the three coordinates
///   and then the on-surface mask, last of all. A patch is 64×64 pixels here, so
///   this is the largest thing a step hands over — and the reason the fit below
///   is a loop rather than a hundred lists.
/// * `stride` — how many values make one row.
/// * `width` — the patch is `width × width` pixels.
/// * `center_id` — the index of the pixel the sensor is looking at.
/// * `normal` — the surface normal there, from `surface_normal_total_least_squares`.
/// * `params` — three f64: the width of the Gaussian that weights the fit as a
///   fraction of the patch, whether to weight it (`0.0` is not) and whether to
///   fit an intercept.
///
/// The answer is nine f64: `k1`, `k2`, the two curvature directions (three values
/// each) and whether they mean anything (`1.0` or `0.0`). Zeros and a zero when
/// the middle pixel is not on the object, which is the reference's answer too.
///
/// ## What this is held to
///
/// `SensorProcessing.principal_curvatures/4` is the reference, and this is its
/// arithmetic in its own order: the same normal equations summed over the same
/// points, the same Gaussian weights normalised over the whole patch, the same
/// elimination with the same tolerance, the same closed form for the two-by-two
/// shape operator. A parity test compares them on random patches and requires
/// equal floats.
#[rustler::nif]
fn principal_curvatures<'a>(
    env: Env<'a>,
    points: Binary,
    stride: u32,
    width: u32,
    center_id: u32,
    normal: Binary,
    params: Binary,
) -> Binary<'a> {
    let mut output = NewBinary::new(env, 9 * 8);
    let answer = curvatures_at(
        points.as_slice(),
        stride as usize,
        width as usize,
        center_id as usize,
        normal.as_slice(),
        params.as_slice(),
    );

    for (index, value) in answer.iter().enumerate() {
        write_f64(&mut output, index, *value);
    }

    output.into()
}

/// Zeros, a zero direction pair and `false`: nothing is defined at this pixel.
const NO_CURVATURES: [f64; 9] = [0.0; 9];

fn curvatures_at(
    points: &[u8],
    stride: usize,
    width: usize,
    centre: usize,
    normal: &[u8],
    params: &[u8],
) -> [f64; 9] {
    let count = points.len() / (stride * 8);

    if count == 0 || centre >= count {
        return NO_CURVATURES;
    }

    let mask_offset = (stride - 1) * 8;
    let mask = |index: usize| f64_at(points, index * stride * 8 + mask_offset);
    let point = |index: usize| {
        [
            f64_at(points, index * stride * 8),
            f64_at(points, index * stride * 8 + 8),
            f64_at(points, index * stride * 8 + 16),
        ]
    };

    // The middle pixel decides whether there is a surface to fit at all.
    if mask(centre) <= 0.0 {
        return NO_CURVATURES;
    }

    let origin = point(centre);
    let normal = [f64_at(normal, 0), f64_at(normal, 8), f64_at(normal, 16)];
    let patch_fraction = f64_at(params, 0);
    let weighted = f64_at(params, 8) != 0.0;
    let intercept = f64_at(params, 16) != 0.0;

    let Some((across_direction, down_direction)) = tangent_frame(&normal) else {
        return NO_CURVATURES;
    };

    let on_object: Vec<usize> = (0..count).filter(|index| mask(*index) > 0.0).collect();
    let weights = fit_weights(count, centre, width, patch_fraction, &on_object, weighted);

    let mut across = Vec::with_capacity(on_object.len());
    let mut down = Vec::with_capacity(on_object.len());
    let mut heights = Vec::with_capacity(on_object.len());

    for index in &on_object {
        let [x, y, z] = point(*index);
        let relative = [x - origin[0], y - origin[1], z - origin[2]];

        across.push(dot3(&relative, &across_direction));
        down.push(dot3(&relative, &down_direction));
        heights.push(dot3(&relative, &normal));
    }

    let Some(fitted) = fit_quadric(&across, &down, &heights, &weights, intercept) else {
        return NO_CURVATURES;
    };

    curvatures_from(&fitted, &normal, &across_direction, &down_direction).unwrap_or(NO_CURVATURES)
}

/// Two directions square to the normal.
///
/// Monty picks the x axis crossed with the normal, unless the normal is along z,
/// in which case it takes z itself. `None` where the reference would raise: a
/// direction of no length is no frame, and a patch that has one has no surface.
fn tangent_frame(normal: &[f64; 3]) -> Option<([f64; 3], [f64; 3])> {
    let across = if normal[2] != 0.0 {
        normalise3([1.0, 0.0, -normal[0] / normal[2]])?
    } else {
        [0.0, 0.0, 1.0]
    };

    let down = normalise3(cross3(normal, &across))?;

    Some((across, down))
}

/// A Gaussian per pixel, normalised over the whole patch, then the on-object ones.
///
/// The reference normalises over every pixel and only then keeps the ones on the
/// object, which is why the weights of a patch hanging off the object's edge do
/// not add up to one — and why this does the same.
fn fit_weights(
    count: usize,
    centre: usize,
    width: usize,
    patch_fraction: f64,
    on_object: &[usize],
    weighted: bool,
) -> Vec<f64> {
    if !weighted {
        return Vec::new();
    }

    let sigma = width as f64 / patch_fraction;
    let normaliser = (2.0 * std::f64::consts::PI).sqrt() * sigma;
    let centre_row = (centre / width) as i64;
    let centre_column = (centre % width) as i64;

    let raw = |index: usize| {
        let row = (index / width) as i64 - centre_row;
        let column = (index % width) as i64 - centre_column;
        let distance = ((row * row + column * column) as f64).sqrt();

        1.0 / normaliser * (-distance * distance / (2.0 * sigma * sigma)).exp()
    };

    let total: f64 = (0..count).map(raw).sum();

    on_object.iter().map(|index| raw(*index) / total).collect()
}

/// The six (or five) unknowns of `n = a u² + b v² + c u v + d u + e v + f`.
///
/// The weighted normal equations, `A = Xᵀ W X` and `b = Xᵀ W n`, solved the way
/// the reference solves them. `None` is a fit with nothing to say — a singular
/// system, which is a patch with too few pixels on the object.
fn fit_quadric(
    across: &[f64],
    down: &[f64],
    heights: &[f64],
    weights: &[f64],
    intercept: bool,
) -> Option<Vec<f64>> {
    let unknowns = if intercept { 6 } else { 5 };
    let weight_of = |index: usize| {
        if weights.is_empty() {
            1.0
        } else {
            weights[index]
        }
    };

    let rows: Vec<Vec<f64>> = (0..across.len())
        .map(|index| {
            let (u, v) = (across[index], down[index]);
            let mut row = vec![u * u, v * v, u * v, u, v];

            if intercept {
                row.push(1.0);
            }

            row
        })
        .collect();

    let mut a = vec![vec![0.0; unknowns]; unknowns];
    let mut b = vec![0.0; unknowns];

    for left in 0..unknowns {
        for right in 0..unknowns {
            let mut sum = 0.0;

            for (index, row) in rows.iter().enumerate() {
                sum += row[left] * (row[right] * weight_of(index));
            }

            a[left][right] = sum;
        }
    }

    for left in 0..unknowns {
        let mut sum = 0.0;

        for (index, row) in rows.iter().enumerate() {
            sum += row[left] * (heights[index] * weight_of(index));
        }

        b[left] = sum;
    }

    solve(&a, &b)
}

/// `guv` and `buv`, and the shape operator between them, as the reference does.
///
/// The eigenvalues of `guv⁻¹ buv` are the principal curvatures and its
/// eigenvectors their directions in the `(u, v)` frame; the largest is answered
/// first.
fn curvatures_from(
    params: &[f64],
    normal: &[f64; 3],
    across_direction: &[f64; 3],
    down_direction: &[f64; 3],
) -> Option<[f64; 9]> {
    let [a, b, c, d, e, ..] = *params else {
        return None;
    };

    let guv = vec![vec![1.0 + d * d, d * e], vec![d * e, 1.0 + e * e]];
    let buv = [[2.0 * a, c], [c, 2.0 * b]];

    let first = solve(&guv, &[buv[0][0], buv[1][0]])?;
    let second = solve(&guv, &[buv[0][1], buv[1][1]])?;

    // `rows_of` of the two solutions: the operator is symmetric once solved, so
    // its rows are the two vectors read across.
    let operator = [[first[0], second[0]], [first[1], second[1]]];
    let [(k1, first_direction), (k2, second_direction)] = eigen_2x2(operator);

    let direction_1 = normalise3(combine(first_direction, across_direction, down_direction))?;

    let direction_2 = normalise3(combine(second_direction, across_direction, down_direction))?;

    // Monty always has the second direction to the right of the first about the
    // normal, so the pair is a right-handed frame.
    let direction_2 = if right_hand_angle(&direction_1, &direction_2, normal) < 0.0 {
        scale3(&direction_2, -1.0)
    } else {
        direction_2
    };

    Some([
        k1,
        k2,
        direction_1[0],
        direction_1[1],
        direction_1[2],
        direction_2[0],
        direction_2[1],
        direction_2[2],
        1.0,
    ])
}

fn combine(weights: [f64; 2], across_direction: &[f64; 3], down_direction: &[f64; 3]) -> [f64; 3] {
    [
        across_direction[0] * weights[0] + down_direction[0] * weights[1],
        across_direction[1] * weights[0] + down_direction[1] * weights[1],
        across_direction[2] * weights[0] + down_direction[2] * weights[1],
    ]
}

fn right_hand_angle(first: &[f64; 3], second: &[f64; 3], normal: &[f64; 3]) -> f64 {
    dot3(&cross3(first, second), normal).atan2(dot3(first, second))
}

/// The eigenvalues and eigenvectors of a two-by-two matrix, largest first.
///
/// The characteristic quadratic solved in closed form, then a null vector for
/// each root — and a repeated eigenvalue answered as the standard basis, which is
/// what a sphere's shape operator is.
fn eigen_2x2([[a, b], [c, d]]: [[f64; 2]; 2]) -> [(f64, [f64; 2]); 2] {
    let trace = a + d;
    let determinant = a * d - b * c;
    let root = (trace * trace / 4.0 - determinant).max(0.0).sqrt();
    let largest = trace / 2.0 + root;

    if root <= 1.0e-12 * largest.abs().max(1.0) {
        return [(largest, [1.0, 0.0]), (largest, [0.0, 1.0])];
    }

    let smaller = trace / 2.0 - root;

    let with_vectors = |value: f64| {
        let null = null_vector([[a - value, b], [c, d - value]]);

        (value, null)
    };

    let first = with_vectors(largest);
    let second = with_vectors(smaller);

    // `Enum.sort_by(&elem(&1, 0), :desc)`, whose sort is stable — the larger
    // root is first, and two roots that compare equal keep their order.
    if second.0 > first.0 {
        [second, first]
    } else {
        [first, second]
    }
}

fn null_vector([[a, b], [c, d]]: [[f64; 2]; 2]) -> [f64; 2] {
    // `Enum.max_by` over the two rows, by their absolute sum: the row that says
    // the most about the direction, and the first of two that say as much.
    let first_size = a.abs() + b.abs();
    let second_size = c.abs() + d.abs();

    let (left, right) = if second_size > first_size {
        (c, d)
    } else {
        (a, b)
    };

    if left == 0.0 && right == 0.0 {
        return [1.0, 0.0];
    }

    let length = (right * right + left * left).sqrt();

    [right / length, -left / length]
}

/// The vector `x` that solves `matrix · x = vector`, or `None` when the matrix
/// has no solution to give.
///
/// Gaussian elimination with partial pivoting, with the reference's tolerance:
/// a pivot smaller than a billionth of the largest entry is a matrix that is
/// singular, and `None` is answered rather than a row of NaN.
fn solve(matrix: &[Vec<f64>], vector: &[f64]) -> Option<Vec<f64>> {
    let count = vector.len();

    if matrix.len() != count {
        return None;
    }

    let mut rows: Vec<Vec<f64>> = matrix
        .iter()
        .enumerate()
        .map(|(index, row)| {
            let mut augmented = row.clone();
            augmented.push(vector[index]);

            augmented
        })
        .collect();

    let tolerance = {
        let largest = rows
            .iter()
            .flat_map(|row| row.iter())
            .fold(0.0_f64, |largest, value| largest.max(value.abs()));

        1.0e-12 * largest.max(1.0)
    };

    for column in 0..count {
        let mut pivot = column;

        for candidate in (column + 1)..count {
            if rows[candidate][column].abs() > rows[pivot][column].abs() {
                pivot = candidate;
            }
        }

        if rows[pivot][column].abs() <= tolerance {
            return None;
        }

        rows.swap(column, pivot);

        let pivot_row = rows[column].clone();

        for row in rows.iter_mut().skip(column + 1) {
            let factor = row[column] / pivot_row[column];

            for (value, pivot_value) in row.iter_mut().zip(pivot_row.iter()) {
                *value -= factor * pivot_value;
            }
        }
    }

    let mut solved = vec![0.0; count];

    for index in (0..count).rev() {
        let mut known = 0.0;

        for column in (index + 1)..count {
            known += rows[index][column] * solved[column];
        }

        solved[index] = (rows[index][count] - known) / rows[index][index];
    }

    Some(solved)
}

fn dot3(left: &[f64; 3], right: &[f64; 3]) -> f64 {
    left[0] * right[0] + left[1] * right[1] + left[2] * right[2]
}

fn cross3(left: &[f64; 3], right: &[f64; 3]) -> [f64; 3] {
    [
        left[1] * right[2] - left[2] * right[1],
        left[2] * right[0] - left[0] * right[2],
        left[0] * right[1] - left[1] * right[0],
    ]
}

fn scale3(vector: &[f64; 3], factor: f64) -> [f64; 3] {
    [vector[0] * factor, vector[1] * factor, vector[2] * factor]
}

/// A unit vector, or `None` for one too short to have a direction — where the
/// reference raises, because a patch that reaches a direction of no length has no
/// surface at that pixel and the answer is "undefined", not a crash.
fn normalise3(vector: [f64; 3]) -> Option<[f64; 3]> {
    let length = (vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]).sqrt();

    if length < 1.0e-6 {
        None
    } else {
        Some([vector[0] / length, vector[1] / length, vector[2] / length])
    }
}

rustler::init!("Elixir.ExTbpMonty.MatcherNif");
