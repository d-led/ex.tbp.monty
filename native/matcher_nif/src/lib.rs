//! The arithmetic a matching step repeats once per stored node.
//!
//! A graph holds a few thousand nodes and a step asks every one of them the same
//! question: how well do the observation's features match yours? In Elixir that
//! question costs about a hundred and fifty words of allocation per node —
//! tuples of columns, lists of values, boxed floats — which came to a quarter of
//! a step's garbage for an answer that is a handful of multiplications and a
//! division. This is that answer as a loop over a flat binary.
//!
//! ## Why the rows are a binary
//!
//! The rows do not change while an episode is being matched: they are written
//! when a graph gains nodes, which is the end of a *training* episode. So they
//! are flattened once, when they are built, and every step reads the same bytes.
//!
//! A `nil` in a row is a feature that node does not have — Monty's NaN. It is
//! written as a NaN here and read back as `nil`, which is why the answer for
//! such a node is a NaN too: no evidence rather than zero evidence.
//!
//! ## What this is held to
//!
//! `DefaultFeatureEvidenceCalculator` is the reference and stays runnable: a
//! parity test compares these answers with its own, node for node, and the
//! native path is only taken when the answers can be the same ones.

use rustler::{Binary, Env, NewBinary};

/// A column of a row, as the calculator describes it: which value of the row it
/// reads, and what kind of comparison applies.
const KIND_NUMERIC: u32 = 0;
const KIND_CIRCULAR: u32 = 1;

/// The range a circular feature wraps over. Monty's hues go round once.
const CIRCULAR_RANGE: f64 = 1.0;

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
        let evidence = row_evidence(rows.as_slice(), index * width * 8, width, &columns, increment);

        output[index * 8..(index + 1) * 8].copy_from_slice(&evidence.to_le_bytes());
    }

    output.into()
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

fn row_evidence(
    rows: &[u8],
    base: usize,
    width: usize,
    columns: &[Column],
    increment: f64,
) -> f64 {
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

rustler::init!("Elixir.ExTbpMonty.MatcherNif");
