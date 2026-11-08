defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater do
  @moduledoc """
  How a learning module decides which hypotheses to keep and how they earn.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/hypotheses_updater.py`,
  a module holding a protocol and its default implementation. The Elixir split
  has the same shape:

    * this module is the protocol, as a behaviour;
    * `Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.DefaultHypothesesUpdater`
      — **ported**: start the space, add a channel that joins late, add this
      observation's evidence, displace between steps.
    * `Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater`
      — **ported**: the same job, but spending stalled steps on new hypotheses
      instead of only accumulating evidence. This is what experiments run.

  A learning module holds an updater as `{module, state}` and dispatches through
  that module, so which strategy a run uses is a construction choice and neither
  implementation knows about the other.

  Monty's protocol also carries `evidence_threshold_config`, which no
  implementation reads — the learning module computes the threshold each step
  and passes it in instead. `new/2` is not a callback either: each updater has
  its own options, and the learning module builds whichever one it was told to.
  """

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses

  @type state :: term()
  @type features :: %{optional(String.t()) => map()}
  @type telemetry :: map()

  @doc """
  Forget what the previous episode taught, keeping the configuration.

  Hypotheses are thrown away at the end of every episode, but a burst in flight
  and the evidence slopes that triggered it belong to the episode too.
  """
  @callback reset(state) :: state

  @doc """
  Mark the start of a step, before any graph's evidence is updated.

  This is where an updater that samples when evidence stalls decides whether
  this is a sampling step. It runs once per step rather than once per graph,
  because the decision depends on the whole hypothesis space.
  """
  @callback begin_step(state) :: state

  @doc "Mark the end of a step, once every graph has been updated."
  @callback end_step(state) :: state

  @doc """
  Move every hypothesis of one graph by `displacement`.

  `nil` means the agent has not moved since the buffer was reset, so nothing
  moves.
  """
  @callback displace_hypotheses(state, Hypotheses.t(), [number()] | nil) :: Hypotheses.t()

  @doc """
  Bring one graph's hypothesis space up to date with this observation.

  Returns the updater, the new hypothesis space — or `nil` when the observation
  carries no channel this graph stores, in which case the caller keeps what it
  had — and whatever telemetry the strategy wants logged for this step.
  """
  @callback update_evidence(
              state,
              Hypotheses.t(),
              features(),
              String.t(),
              float()
            ) :: {state, Hypotheses.t() | nil, telemetry()}
end
