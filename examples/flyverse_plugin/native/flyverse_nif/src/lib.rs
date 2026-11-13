//! FlyVerse on the BEAM: a spiking connectome that is stepped inside a NIF.
//!
//! Everything that computes is `flyverse`'s own code — `pack.rs` loads and
//! validates the signed source-major CSR connectome, `lif.rs` advances every
//! neuron by one 0.1 ms tick in Brian2's order — and this crate is the
//! boundary: it holds one connectome per pack and one simulation per policy,
//! drives the neurons a caller names at the rates a caller asks for, and counts
//! the spikes of the neurons a caller wants to read.
//!
//! ## What a caller can name, and why nothing is named here
//!
//! There are no neuron-group names in this crate on purpose. The flyverse
//! `assets/*_neural_io.json` annotations are a *dataset* (CC BY 4.0) and not
//! this crate's to ship; a caller that has them maps a group to model indices
//! in Elixir and passes the indices. A caller with a three-neuron network of
//! its own passes three indices. The engine is the same engine either way, and
//! a number that means "the left wing-steering motor neurons" is a fact about
//! the pack, not about the simulation.
//!
//! ## The drive is Poisson, and it is the same Poisson
//!
//! `flyverse::lif::StimGen` fires each target with probability `rate * dt` per
//! tick, drawing from a hash of `(seed, tick, target position)`. A policy
//! changes its drive on every step, so a generator rebuilt per step would
//! restart that stream and repeat the same four spikes for ever. The sampler
//! below is the same hash, evaluated against one tick counter owned by the
//! simulation — and `sampler_matches_stim_gen` holds the copy to the original,
//! so a change upstream is a test failure here rather than a quiet divergence.
//!
//! ## One pack leak, on purpose
//!
//! `Connectome::load` keeps its arrays for the life of the process
//! (`Box::leak`), because the whole point of that loader is that a 24-million
//! edge graph is not copied per step. So a pack is opened **once per VM** and
//! shared: `FlyversePlugin.Network` memoises it. Opening one per episode would
//! leak a few hundred megabytes an episode, which is the sentence a reader of
//! that module needs to find.
//!
//! ## A resource does not cross a node
//!
//! A `ResourceArc` is a term the BEAM of *this* node understands. A policy that
//! holds one cannot be sent to another node, which is why the policy plugin
//! says `placement: :owner_only`: the simulation stays where it was opened and
//! the policy value that travels is the name of it.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use flyverse::lif::{Lif, DT_MS};
use flyverse::pack::Connectome;
use rustler::{Encoder, Env, ResourceArc, Term};

/// A validated connectome, and nothing else. Read-only once loaded, so handing
/// it to several simulations is the immutable sharing the BEAM is built for.
struct ConnectomeResource {
    connectome: Connectome,
}

// Not decoration: `resource_impl` is what submits the type to Rustler's
// inventory, and without it `ResourceArc::new` panics.
#[rustler::resource_impl]
impl rustler::Resource for ConnectomeResource {}

/// One group of neurons a caller drives, at whatever rate the caller asks for
/// on the window that is stepping.
struct Drive {
    /// Model indices, in the pack's own order.
    targets: Vec<u32>,
    /// Mixed into the hash so two groups at the same rate do not receive the
    /// same events — `sim.rs`'s `mk` closure mixes a tag the same way.
    seed: u64,
}

/// The mutable half of a simulation: what a `window/4` changes.
struct Inner {
    lif: Lif,
    /// Poisson ticks taken, monotone across windows and across `rates` changes.
    tick: u64,
    spikes: u64,
}

/// One policy's simulation: its neurons, its state, and what it reads out.
struct Simulation {
    inner: Mutex<Inner>,
    drives: Vec<Drive>,
    /// One set of readouts per caller-named group, counted per window.
    readouts: Vec<Vec<u32>>,
    /// Neuron index -> the readouts it belongs to, built once: a readout set
    /// the size of a real neuron group is not searched per fired spike.
    readout_of: HashMap<u32, Vec<usize>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Simulation {}

/// The refusal shape every fallible NIF here answers: a code a caller can branch
/// on and a sentence a person can read.
type Refusal = (String, String);

fn refusal(code: &str, message: impl Into<String>) -> Refusal {
    (code.to_string(), message.into())
}

/// Always true, from the native side: the only way to know this library loaded.
///
/// `FlyversePlugin.Native.loaded?/0` treats a `:nif_not_loaded` raise as the
/// answer "no", which is how a VM that never built the crate says so.
#[rustler::nif]
fn available() -> bool {
    true
}

/// Opens the connectome pack in `directory`, validated as flyverse validates it.
///
/// Four arrays and a manifest, exactly as `flyverse census` reads them. A pack
/// that fails validation is refused with the loader's own sentence, because it
/// names the array and the index.
#[rustler::nif]
fn open(directory: String) -> Result<ResourceArc<ConnectomeResource>, Refusal> {
    let connectome = Connectome::load(Path::new(&directory))
        .map_err(|error| refusal("pack", format!("{error:#}")))?;

    Ok(ResourceArc::new(ConnectomeResource { connectome }))
}

/// How many neurons and how many signed edges the pack holds.
#[rustler::nif]
fn census(connectome: ResourceArc<ConnectomeResource>) -> (u64, u64) {
    (
        connectome.connectome.n as u64,
        connectome.connectome.m as u64,
    )
}

/// A simulation over `connectome`, with `drives` given their first rates.
///
/// `readouts` names the neuron sets `window/4` counts, so that a caller reading
/// "the left steering neurons" and a caller reading "neuron 2" are the same
/// question with a different list.
#[rustler::nif]
fn new(
    connectome: ResourceArc<ConnectomeResource>,
    drives: Vec<Vec<u32>>,
    rates_hz: Vec<f64>,
    readouts: Vec<Vec<u32>>,
    seed: u64,
) -> Result<ResourceArc<Simulation>, Refusal> {
    if drives.len() != rates_hz.len() {
        return Err(refusal(
            "drives",
            format!(
                "{} drive group(s) but {} rate(s): a group without a rate is a \
                 group that cannot be driven",
                drives.len(),
                rates_hz.len()
            ),
        ));
    }

    let drives: Vec<Drive> = drives
        .into_iter()
        .enumerate()
        .map(|(index, targets)| Drive {
            targets,
            seed: seed ^ (index as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15),
        })
        .collect();

    let mut readout_of: HashMap<u32, Vec<usize>> = HashMap::new();
    for (slot, set) in readouts.iter().enumerate() {
        for &neuron in set {
            readout_of.entry(neuron).or_default().push(slot);
        }
    }

    Ok(ResourceArc::new(Simulation {
        inner: Mutex::new(Inner {
            lif: Lif::new(&connectome.connectome),
            tick: 0,
            spikes: 0,
        }),
        drives,
        readouts,
        readout_of,
    }))
}

/// Steps `ticks` of 0.1 ms with each drive group at its rate, and answers what
/// the readouts did.
///
/// The answer is `{counts, window_spikes, total_spikes}`: one count per readout
/// in the order `new/5` took them, the spikes this window added, and the spikes
/// since the last `reset/1`. Counts are a number of spikes rather than a rate
/// because a 2 ms window cannot honestly carry a rate: at 0.1 ms a tick, one
/// spike in a window is 500 Hz, and a policy that wants a rate wants an average
/// it keeps itself.
#[rustler::nif]
fn window(
    simulation: ResourceArc<Simulation>,
    connectome: ResourceArc<ConnectomeResource>,
    ticks: u32,
    rates_hz: Vec<f64>,
) -> Result<(Vec<u32>, u64, u64), Refusal> {
    if rates_hz.len() != simulation.drives.len() {
        return Err(refusal(
            "drives",
            format!(
                "{} drive group(s) but {} rate(s)",
                simulation.drives.len(),
                rates_hz.len()
            ),
        ));
    }

    let mut inner = lock(&simulation)?;
    let mut counts = vec![0u32; simulation.readouts.len()];
    let mut events: Vec<(u32, u32)> = Vec::new();
    let mut spikes = 0u64;

    for _ in 0..ticks {
        events.clear();

        for (drive, &rate_hz) in simulation.drives.iter().zip(rates_hz.iter()) {
            let probability = (rate_hz.max(0.0)) * DT_MS as f64 / 1000.0;

            for (position, &target) in drive.targets.iter().enumerate() {
                if draw(drive.seed, inner.tick, position as u64) < probability {
                    events.push((target, 1));
                }
            }
        }

        inner.lif.step(&connectome.connectome, &events);
        spikes += inner.lif.fired.len() as u64;

        for &neuron in &inner.lif.fired {
            if let Some(slots) = simulation.readout_of.get(&neuron) {
                for &slot in slots {
                    counts[slot] += 1;
                }
            }
        }

        inner.tick += 1;
    }

    inner.spikes += spikes;

    let total = inner.spikes;

    Ok((counts, spikes, total))
}

/// Starts the next episode from the connectome's resting state.
///
/// The Poisson stream restarts with it: two episodes of one policy are meant to
/// be two episodes, and a stream that continued across them would make the
/// second one depend on how long the first ran.
///
/// Answers `:ok` rather than `{:ok, {}}`: a reset has nothing to report, and a
/// caller matching on a unit tuple is a caller reading Rust's type through the
/// boundary.
#[rustler::nif]
fn reset<'a>(env: Env<'a>, simulation: ResourceArc<Simulation>) -> Term<'a> {
    match lock(&simulation) {
        Ok(mut inner) => {
            inner.lif.reset();
            inner.tick = 0;
            inner.spikes = 0;

            rustler::types::atom::ok().to_term(env)
        }

        Err(refusal) => ("error", refusal).encode(env),
    }
}

fn lock(simulation: &Simulation) -> Result<MutexGuard<'_, Inner>, Refusal> {
    simulation.inner.lock().map_err(|_poisoned| {
        refusal(
            "poisoned",
            "the simulation was left locked by a step that failed; rebuild the \
             policy rather than stepping it again",
        )
    })
}

/// `flyverse::lif::StimGen`'s draw, against a tick the caller owns.
///
/// Same constants, same shift, same divisor, so that one drive at one rate is
/// the stream `StimGen` would have produced for the same seed and tick.
fn draw(seed: u64, tick: u64, position: u64) -> f64 {
    let mut z = seed
        .wrapping_add(tick.wrapping_mul(0x9E37_79B9_7F4A_7C15))
        .wrapping_add(position.wrapping_mul(0xBF58_476D_1CE4_E5B9));
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^= z >> 31;

    (z >> 11) as f64 / ((1u64 << 53) as f64)
}

rustler::init!("Elixir.FlyversePlugin.Native");

#[cfg(test)]
mod tests {
    use super::draw;
    use flyverse::lif::StimGen;

    /// The sampler is a copy, so it is held to the original: ten ticks of a
    /// three-neuron drive at 150 Hz, spike for spike.
    #[test]
    fn sampler_matches_stim_gen() {
        let targets = vec![7u32, 11, 13];
        let mut stim = StimGen::new(targets.clone(), 150.0, 42);
        let probability = 150.0 * flyverse::lif::DT_MS as f64 / 1000.0;

        for tick in 0..10u64 {
            let theirs: Vec<(u32, u32)> = stim.next_events().to_vec();

            let ours: Vec<(u32, u32)> = targets
                .iter()
                .enumerate()
                .filter(|(position, _)| draw(42, tick, *position as u64) < probability)
                .map(|(_, &target)| (target, 1))
                .collect();

            assert_eq!(ours, theirs, "tick {tick}");
        }
    }
}
