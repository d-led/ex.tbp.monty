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

rustler::init!("Elixir.ExTbpMonty.MatcherNif");
