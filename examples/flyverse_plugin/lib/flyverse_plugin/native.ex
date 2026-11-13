defmodule FlyversePlugin.Native do
  @moduledoc """
  The Rust engine: flyverse's leaky integrate-and-fire step, in this VM.

  Every call here is one of flyverse's own files doing the work — `pack.rs`
  validates the signed source-major CSR connectome, `lif.rs` advances it in
  Brian2's order — and the crate in `native/flyverse_nif` is only the boundary.
  There is no second simulator in Elixir to drift from it.

  ## Handles do not cross a node

  A connectome and a simulation are NIF resources: terms this node's BEAM
  understands and no other's. That is why `FlyversePlugin.Policy` says
  `placement: :owner_only` — the simulation stays where it was opened, and what
  travels with a policy is the name of it.

  A NIF is a library the BEAM loads into itself, so its absence is a raised
  `ErlangError` rather than a returned error: `loaded?/0` is the question a
  caller asks once, and `open/1` is where an answer becomes a sentence.
  """

  use Rustler, otp_app: :flyverse_plugin, crate: "flyverse_nif"

  @doc "Whether this VM built and loaded the engine."
  @spec loaded?() :: boolean()
  def loaded? do
    available()
  rescue
    ErlangError -> false
  end

  @doc "True, from the native side — the only way to know it is loaded."
  def available, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Opens the connectome pack in `directory`.

  Four arrays — `neuron_ids.npy`, `row_ptr.npy`, `destinations.npy`,
  `signed_counts.npy` — validated as flyverse validates them, so a pack that is
  the wrong shape is refused with the array and the index that disagree.
  """
  def open(_directory), do: :erlang.nif_error(:nif_not_loaded)

  @doc "How many neurons and how many signed edges the pack holds."
  def census(_connectome), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  A simulation over `connectome`.

  `drives` are the neuron groups a caller stimulates, `rates_hz` their first
  rates, `readouts` the groups `window/4` counts. Nothing here knows what a
  group *means*: that is a fact about the pack, read from its plan by
  `FlyversePlugin.Networks`.
  """
  def new(_connectome, _drives, _rates_hz, _readouts, _seed),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Steps `ticks` of 0.1 ms and answers `{counts, window_spikes, total_spikes}`.

  One count per readout, in the order `new/5` took them. Counts rather than
  rates because a 2 ms window cannot honestly carry a rate: one spike in a
  window is 500 Hz, and a policy that wants a rate averages it itself.
  """
  def window(_simulation, _connectome, _ticks, _rates_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Starts the next episode from the connectome's resting state."
  def reset(_simulation), do: :erlang.nif_error(:nif_not_loaded)
end
