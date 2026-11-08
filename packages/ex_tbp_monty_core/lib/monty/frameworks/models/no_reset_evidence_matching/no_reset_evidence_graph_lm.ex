defmodule Monty.Frameworks.Models.NoResetEvidenceMatching.NoResetEvidenceGraphLM do
  @moduledoc """
  An evidence learning module that is never told an episode has ended.

  Mirrors `frameworks/models/no_reset_evidence_matching.py::NoResetEvidenceGraphLM`,
  the module an unsupervised-inference experiment runs: the object under the
  sensor changes without any signal that it changed, so the module cannot be
  reset between objects — it has to notice the change itself, from evidence
  falling away. Its whole reason to exist is the comparison the ordinary module
  makes at an episode boundary.

  ## What it changes

    * **It remembers where the sensor was**, itself. `EvidenceGraphLM` reads the
      buffer for that, and the model empties every module's buffer when the
      object changes (`NoResetEvidenceGraphMatching.reset/0`), so the buffer
      cannot be the memory here. Both are kept in step: `_add_displacements`
      writes the location to this module *and* to the buffer.
    * **"The agent has moved" means "this module has seen the sensor before"**,
      not "the buffer has an entry". On the first step after an object change the
      buffer is empty and the sensor has moved — the module must displace its
      hypotheses by the journey from the old object to the new one, which is
      exactly what the ordinary module does *not* do on its first step.
    * **A location-only step displaces the hypotheses** without touching
      evidence, from this module's own memory of the last place.
    * **The goal generator does not wait longer** between objects
      (`wait_growth_multiplier` 1): waiting is for a sensor that cannot find the
      object it is on, and here the object is simply replaced.
    * **It always updates hypotheses by burst sampling**, which is Monty's
      constructor: `kwargs["hypotheses_updater_class"]` is set whenever the
      attribute is missing *from the dict*, which is always, so a config cannot
      choose another updater for this class.

  ## Why a wrapper rather than inheritance

  In Monty this is a subclass of `EvidenceGraphLM` that overrides four methods.
  Elixir has no inheritance, so — the same decision `SurfacePolicyCurvatureInformed`
  and `InformedPolicy` already carry (`docs/monty-differences.md` §2.9) — it is a
  second struct holding an `EvidenceGraphLM` and answering the learning module's
  callbacks by delegation, with the four overrides written out. The four are
  `matching_step`, `exploratory_step`, `reset_stm` and the displacement helpers.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.LearningModule

  alias Monty.Cmp
  alias Monty.Cmp.Message
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.Mixins.NoResetEvidence.TheoreticalLimitLMLoggingMixin
  alias Monty.Runtime

  @burst_sampling "tbp.monty.frameworks.models.evidence_matching.burst_sampling.BurstSamplingHypothesesUpdater"

  @evidence_graph_lm "tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM"

  @enforce_keys [:lm]
  defstruct [:lm, last_location: nil]

  @typedoc """
  The module Monty's unsupervised-inference experiments run: an evidence
  learning module plus where the sensor was when it last reported.

  `last_location` is `nil` until the module has seen a sensor percept, and is
  the one thing a reset clears along with the rest of the short-term memory.
  """
  @type t :: %__MODULE__{lm: EvidenceGraphLM.t(), last_location: [float()] | nil}

  # -- construction --------------------------------------------------------

  @doc """
  A no-reset module over the memory `EvidenceGraphLM.new/2` was given.
  """
  @spec new(EvidenceGraphLM.t()) :: t()
  def new(%EvidenceGraphLM{} = lm), do: %__MODULE__{lm: no_wait_growth(lm)}

  @doc """
  The module a config's `_target_` names, built from it.

  Two things about the config are this class's rather than the evidence
  module's, and both are replaced before the evidence module reads it. The
  target is this class — the config asked for it — while the module it wraps is
  `EvidenceGraphLM`, which refuses to be built from a config naming anything
  else. And the updater is forced to burst sampling, which is what Monty's
  `__init__` does (`if not hasattr(kwargs, "hypotheses_updater_class")` asks a
  dict whether it has an attribute: it never does), so the module's
  `hypotheses_updater_args` are honoured and its choice of updater is not.
  """
  @spec from_config(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_config(config, options \\ []) when is_map(config) do
    with {:ok, lm} <- EvidenceGraphLM.from_config(evidence_config(config), options) do
      {:ok, new(lm)}
    end
  end

  defp evidence_config(config) do
    config
    |> Map.put("_target_", @evidence_graph_lm)
    |> Map.put("hypotheses_updater_class", @burst_sampling)
  end

  # Monty sets `gsg.wait_growth_multiplier = 1` on whatever generator the module
  # has; only the evidence generator reads it, and a generator without the field
  # is left alone rather than given one.
  defp no_wait_growth(%EvidenceGraphLM{gsg: %{__struct__: module} = gsg} = lm)
       when module == Monty.Frameworks.Models.GoalGeneration.EvidenceGoalGenerator,
       do: %{lm | gsg: %{gsg | wait_growth_multiplier: 1}}

  defp no_wait_growth(%EvidenceGraphLM{} = lm), do: lm

  # -- steps ---------------------------------------------------------------

  @doc """
  One matching step, and the difference from `EvidenceGraphLM`'s is one line.

  Monty's override asks *this module* whether the agent has moved, and displaces
  from *this module's* memory of where the sensor was; everything after that is
  the evidence module's step, with the mixin's statistics in place of its own.
  """
  @impl true
  @spec matching_step([Message.t()], Monty.Context.t(), t()) :: {:ok, t()} | {:error, term()}
  def matching_step(percepts, ctx, %__MODULE__{} = lm) do
    if Runtime.location_only_step?(percepts) do
      {:ok, displace(lm, percepts)}
    else
      # Monty: the very first step has not moved; every step after it has,
      # because this module has been somewhere before — an object change is a
      # movement, not a beginning.
      moved? = lm.last_location != nil
      observed = feature_percepts(percepts)

      with {:ok, percepts, here} <- place(lm, percepts),
           {:ok, lm} <- store(lm, percepts, here) do
        inner =
          lm.lm
          |> EvidenceGraphLM.compute_possible_matches(observed, moved?)
          |> conclude_no_match_if_nothing_possible()
          |> step_goal_generator(ctx, observed)
          |> record()

        {:ok, %{lm | lm: inner}}
      end
    end
  end

  @doc """
  One exploratory step: buffer what was seen, move the hypotheses with the
  sensor, test nothing.
  """
  @impl true
  @spec exploratory_step([Message.t()], Monty.Context.t(), t()) :: {:ok, t()} | {:error, term()}
  def exploratory_step(percepts, _ctx, %__MODULE__{} = lm) do
    if Runtime.location_only_step?(percepts) do
      {:ok, displace(lm, percepts)}
    else
      with {:ok, percepts, here} <- place(lm, percepts) do
        store(lm, percepts, here)
      end
    end
  end

  @doc """
  Clears the short-term memory, remembering nothing of where the sensor was.

  Monty's `reset_stm`: the evidence module's, plus this module's own field —
  which is what makes the next step an unmoved one again.
  """
  @impl true
  @spec reset_stm(t()) :: t()
  def reset_stm(%__MODULE__{} = lm),
    do: %{lm | lm: EvidenceGraphLM.reset_stm(lm.lm), last_location: nil}

  # Monty's `_add_displacements`: the displacement is measured from this module's
  # last location, and the location is remembered here afterwards. The buffer is
  # written by the append that follows, which is why the step returns it.
  defp place(%__MODULE__{} = lm, percepts) do
    with {:ok, placed} <- EvidenceGraphLM.add_displacements(lm.lm, percepts, lm.last_location) do
      {:ok, placed, Cmp.location_mean(Enum.filter(placed, &Message.from_sensor_module?/1))}
    end
  end

  defp store(%__MODULE__{} = lm, percepts, here) do
    with {:ok, buffer} <- FeatureAtLocationBuffer.append(lm.lm.buffer, percepts) do
      buffer =
        Enum.reduce(percepts, buffer, &FeatureAtLocationBuffer.append_input_percepts(&2, &1))

      {:ok, %{lm | lm: %{lm.lm | buffer: buffer}, last_location: here}}
    end
  end

  # Monty's `_displace_hypotheses`: nothing is tested, so evidence is untouched
  # and the most likely hypothesis is the same one afterwards.
  defp displace(%__MODULE__{} = lm, percepts) do
    inner = EvidenceGraphLM.displace_hypotheses(lm.lm, percepts, lm.last_location)

    # The evidence module writes the place it arrived at into the buffer, and the
    # buffer is where this module reads it back from — `_displace_hypotheses`
    # sets both fields.
    %{lm | lm: inner, last_location: inner.buffer.last_location}
  end

  defp feature_percepts(percepts), do: Enum.filter(percepts, & &1.process_features_in_lm)

  defp conclude_no_match_if_nothing_possible(%EvidenceGraphLM{possible_matches: []} = inner),
    do: EvidenceGraphLM.set_individual_ts(inner, :no_match)

  defp conclude_no_match_if_nothing_possible(%EvidenceGraphLM{} = inner), do: inner

  # Monty steps its own generator with this module's current state: the generator
  # holds a copy, and the schedule it has built belongs to the module.
  defp step_goal_generator(%EvidenceGraphLM{gsg: nil} = inner, _ctx, _percepts), do: inner

  defp step_goal_generator(%EvidenceGraphLM{} = inner, ctx, percepts) do
    gsg = inner.gsg.__struct__.point_at(inner.gsg, inner)
    %{inner | gsg: gsg.__struct__.step(gsg, ctx, percepts)}
  end

  # Monty's `collect_stats_to_save` followed by `buffer.update_stats/2`, with the
  # mixin's statistics where the evidence module would write its own.
  defp record(%EvidenceGraphLM{} = inner) do
    {inner, stats} =
      EvidenceGraphLM.collect_stats_to_save(
        inner,
        &TheoreticalLimitLMLoggingMixin.add_detailed_stats/2
      )

    buffer =
      FeatureAtLocationBuffer.update_stats(inner.buffer, stats, append: inner.has_detailed_logger)

    %{inner | buffer: buffer}
  end

  # -- the callbacks this module does not change ---------------------------
  #
  # A wrapper answers the learning module's callbacks by asking the evidence
  # module it holds. Four shapes come back from those callbacks, and each helper
  # below is one of them, so the delegation reads as what the inner module
  # answered.

  @impl true
  def send_out_vote(%__MODULE__{} = lm), do: pair(lm, &EvidenceGraphLM.send_out_vote/1)

  @impl true
  def receive_votes(votes, %__MODULE__{} = lm),
    do: ok(lm, &EvidenceGraphLM.receive_votes(votes, &1))

  @impl true
  def propose_goals(%__MODULE__{} = lm), do: pair(lm, &EvidenceGraphLM.propose_goals/1)

  @impl true
  def propose_region(%__MODULE__{} = lm), do: pair(lm, &EvidenceGraphLM.propose_region/1)

  @impl true
  def get_output(%__MODULE__{} = lm), do: pair(lm, &EvidenceGraphLM.get_output/1)

  @impl true
  def update_terminal_condition(%__MODULE__{} = lm),
    do: reversed(lm, &EvidenceGraphLM.update_terminal_condition/1)

  @impl true
  def update_stats_after_vote(%__MODULE__{} = lm),
    do: state(lm, &EvidenceGraphLM.update_stats_after_vote/1)

  @impl true
  def add_lm_processing_to_buffer_stats(%__MODULE__{} = lm, processed),
    do: state(lm, &EvidenceGraphLM.add_lm_processing_to_buffer_stats(&1, processed))

  @impl true
  def set_terminal_state(%__MODULE__{} = lm, terminal_state),
    do: state(lm, &EvidenceGraphLM.set_terminal_state(&1, terminal_state))

  @impl true
  def set_experiment_mode(%__MODULE__{} = lm, mode),
    do: state(lm, &EvidenceGraphLM.set_experiment_mode(&1, mode))

  @impl true
  def update_ltm_from_stm(%__MODULE__{} = lm),
    do: state(lm, &EvidenceGraphLM.update_ltm_from_stm/1)

  @impl true
  def set_target(%__MODULE__{} = lm, primary_target),
    do: state(lm, &EvidenceGraphLM.set_target(&1, primary_target))

  @impl true
  def set_stepwise_target(%__MODULE__{} = lm, label),
    do: state(lm, &EvidenceGraphLM.set_stepwise_target(&1, label))

  @impl true
  def fixme_update_ground_truth(%__MODULE__{} = lm),
    do: state(lm, &EvidenceGraphLM.fixme_update_ground_truth/1)

  @impl true
  def clear_buffers(%__MODULE__{} = lm), do: state(lm, &EvidenceGraphLM.clear_buffers/1)

  @impl true
  def clear_conclusion(%__MODULE__{} = lm), do: state(lm, &EvidenceGraphLM.clear_conclusion/1)

  @impl true
  def set_primary_target(%__MODULE__{} = lm, primary_target),
    do: state(lm, &EvidenceGraphLM.set_primary_target(&1, primary_target))

  @impl true
  def graph_memory(%__MODULE__{lm: inner}), do: EvidenceGraphLM.graph_memory(inner)

  @impl true
  def observation_processed?(%__MODULE__{lm: inner}),
    do: EvidenceGraphLM.observation_processed?(inner)

  @impl true
  def conclusion(%__MODULE__{lm: inner}), do: EvidenceGraphLM.conclusion(inner)

  defp state(%__MODULE__{lm: inner} = lm, fun), do: %{lm | lm: fun.(inner)}

  defp pair(%__MODULE__{lm: inner} = lm, fun) do
    {value, inner} = fun.(inner)
    {value, %{lm | lm: inner}}
  end

  defp ok(%__MODULE__{lm: inner} = lm, fun) do
    {:ok, inner} = fun.(inner)
    {:ok, %{lm | lm: inner}}
  end

  defp reversed(%__MODULE__{lm: inner} = lm, fun) do
    {inner, value} = fun.(inner)
    {%{lm | lm: inner}, value}
  end
end
