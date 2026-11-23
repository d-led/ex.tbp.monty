//! A k-nearest-neighbour index for `Monty.Frameworks.Utils.KdTree`.
//!
//! Monty asks scipy's `cKDTree`; the Elixir port answers the same question with
//! its own tree, at about 6 µs a query instead of scipy's 2. This is that index
//! in Rust (the `kiddo` crate), which answers in ~0.45 µs and — the part that
//! matters at seventy-seven objects — does not get slower as the graph grows.
//!
//! ## The shape of the call
//!
//! A step asks about twenty thousand questions of one graph, so the boundary is
//! crossed once per step, not once per query: `nearest_many` takes a flat binary
//! of query points and answers a flat binary of ids. Encoding twenty thousand
//! Elixir lists would cost more than the search. `kiddo`'s own batch query is
//! what answers it, so the tree's scratch and its leaf walk are set up once for
//! the whole batch rather than once a question.
//!
//! ## Why there is no lock
//!
//! A graph is immutable while an episode matches against it: nodes are appended
//! only at the end of a *training* episode, which builds a new graph. So the
//! index is built once, shared read-only, and never mutated — no `RwLock`, and
//! nothing to synchronise on the query path. `kiddo`'s immutable tree is exactly
//! that promise, and the crate's thread pool is turned off: the query is already
//! on a dirty scheduler, and a pool of its own would fight the BEAM's for cores.
//!
//! ## Determinism
//!
//! `kiddo` does not promise an order for equidistant neighbours; `nearest/3` in
//! the Elixir tree promises ties go to the lower id. So the answers are sorted
//! here by `(distance, id)` before they leave, and the parity test between the
//! two engines holds them to the same answer wherever the distances differ.

use kiddo::{ImmutableKdTree, SquaredEuclidean};
use rustler::{Binary, Encoder, Env, NewBinary, ResourceArc, Term};
use std::num::NonZeroUsize;

/// How many f64s make one point.
const DIMENSIONS: usize = 3;

/// The index: an immutable tree over the graph's positions, and how many there
/// are. `kiddo`'s recommended read-heavy variant — array storage, a leaf of 32 —
/// with the item being the point's own index in the slice it was built from.
type Tree = ImmutableKdTree<f64, DIMENSIONS>;

struct Index {
    tree: Tree,
    nodes: usize,
}

#[rustler::resource_impl]
impl rustler::Resource for Index {}

/// The id written where a query found fewer neighbours than it asked for.
const NO_NEIGHBOUR: u32 = u32::MAX;

/// Builds an index over `positions`, a flat binary of `3 * n` f64 values.
///
/// Points are taken from the binary in order, so a point's id is its index —
/// which is what every caller in this port uses, and what `KdTree.build/1`
/// checks before handing its points over.
/// Always true, from the native side: the only way to know this library loaded.
#[rustler::nif]
fn available() -> bool {
    true
}

#[rustler::nif]
fn build<'a>(env: Env<'a>, positions: Binary) -> Term<'a> {
    let points = read_points(positions.as_slice());

    // An empty graph is a tree with nothing in it rather than an error: a caller
    // that builds an index before its first node is not doing anything wrong.
    let tree = if points.is_empty() {
        Tree::default()
    } else {
        Tree::new_from_slice(&points).expect("a slice of finite points builds a tree")
    };

    let index = ResourceArc::new(Index {
        nodes: tree.size(),
        tree,
    });

    index.encode(env)
}

/// The ids of the `k` points nearest each of `queries`, nearest first.
///
/// `queries` is a flat binary of `3 * m` f64 values; the answer is `m * k` u32
/// ids, with `u32::MAX` for a query that found fewer than `k`.
///
/// A step's worth of questions is one call, and a step's worth is up to tens of
/// thousands of queries — the work is microseconds but a call is not free to set
/// up, so it is scheduled on a dirty CPU scheduler rather than blocking a normal
/// one.
#[rustler::nif(schedule = "DirtyCpu")]
fn nearest_many<'a>(
    env: Env<'a>,
    index: ResourceArc<Index>,
    queries: Binary,
    k: usize,
) -> Term<'a> {
    let found = answers(&index, queries.as_slice(), k);
    encode_ids(env, &found, k)
}

/// The same answers with the distance to each, as `{ids, distances}`.
///
/// Two flat binaries rather than one interleaved: a caller that compares answers
/// needs the number as well as the id, and neither half is cheaper to build.
#[rustler::nif(schedule = "DirtyCpu")]
fn nearest_many_with_distances<'a>(
    env: Env<'a>,
    index: ResourceArc<Index>,
    queries: Binary,
    k: usize,
) -> Term<'a> {
    let found = answers(&index, queries.as_slice(), k);
    let k = k.min(index.nodes);

    let mut binary = NewBinary::new(env, found.len() * k * std::mem::size_of::<f64>());
    let bytes = binary.as_mut_slice();

    for (query_number, neighbours) in found.iter().enumerate() {
        for slot in 0..k {
            let distance = neighbours
                .get(slot)
                .map(|(squared, _id)| squared.sqrt())
                .unwrap_or(f64::INFINITY);

            let offset = (query_number * k + slot) * std::mem::size_of::<f64>();
            bytes[offset..offset + std::mem::size_of::<f64>()]
                .copy_from_slice(&distance.to_le_bytes());
        }
    }

    (encode_ids(env, &found, k), Term::from(binary)).encode(env)
}

/// How many points the index holds.
#[rustler::nif]
fn nodes(index: ResourceArc<Index>) -> usize {
    index.nodes
}

/// One entry per query: its neighbours, nearest first, as `(squared distance, id)`.
///
/// `kiddo`'s batch query answers a whole step in one call — the scratch the leaves
/// are walked with is set up once, and the walk is shared by every question — and
/// it does not promise an order for equidistant neighbours; sorting by
/// `(distance, id)` is what makes two runs of the same episode choose the same
/// nodes.
fn answers(index: &Index, queries: &[u8], k: usize) -> Vec<Vec<(f64, u32)>> {
    let points = read_points(queries);
    let k = k.min(index.nodes);

    // No neighbours asked for, or none to find: an empty answer a query.
    if k == 0 || points.is_empty() {
        return vec![Vec::new(); points.len()];
    }

    let quantity = NonZeroUsize::new(k).expect("k is not zero");

    index
        .tree
        .query_batch(&points)
        .nearest_n::<SquaredEuclidean<f64>>(quantity)
        .execute()
        .into_iter()
        .map(|found| {
            let mut found: Vec<(f64, u32)> = found
                .into_iter()
                .map(|neighbour| (neighbour.distance, neighbour.item))
                .collect();

            found.sort_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal));

            found
        })
        .collect()
}

fn encode_ids<'a>(env: Env<'a>, found: &[Vec<(f64, u32)>], k: usize) -> Term<'a> {
    let mut binary = NewBinary::new(env, found.len() * k * std::mem::size_of::<u32>());
    let bytes = binary.as_mut_slice();

    for (query_number, neighbours) in found.iter().enumerate() {
        for slot in 0..k {
            let id = neighbours
                .get(slot)
                .map(|(_distance, id)| *id)
                .unwrap_or(NO_NEIGHBOUR);

            let offset = (query_number * k + slot) * std::mem::size_of::<u32>();
            bytes[offset..offset + std::mem::size_of::<u32>()].copy_from_slice(&id.to_le_bytes());
        }
    }

    binary.into()
}

fn read_points(bytes: &[u8]) -> Vec<[f64; DIMENSIONS]> {
    bytes
        .chunks_exact(DIMENSIONS * std::mem::size_of::<f64>())
        .map(|chunk| {
            let mut point = [0.0f64; DIMENSIONS];

            for (axis, value) in point.iter_mut().enumerate() {
                let start = axis * std::mem::size_of::<f64>();
                let mut raw = [0u8; std::mem::size_of::<f64>()];
                raw.copy_from_slice(&chunk[start..start + std::mem::size_of::<f64>()]);
                *value = f64::from_le_bytes(raw);
            }

            point
        })
        .collect()
}

rustler::init!("Elixir.ExTbpMonty.Core.KdTreeNif");
