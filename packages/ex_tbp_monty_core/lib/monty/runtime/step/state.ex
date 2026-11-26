defmodule Monty.Runtime.Step.State do
  @moduledoc """
  What a step coordinator needs to know between steps, with the wiring
  normalised once at start, and the model-level bookkeeping Monty keeps on
  `MontyBase`.

  Monty's connection matrices (`sm_to_lm_matrix`, `lm_to_lm_matrix`,
  `lm_to_lm_vote_matrix`) are lists indexed by module position in Python; here
  they arrive as maps keyed by module id. This struct inverts them once — for
  every learning module, which sensors feed it and which modules feed it from
  above — so the step loop reads a plain map instead of defensive lookups on
  every phase.

  Two counts are deliberately distinct. `step` is how many steps this episode
  has taken, and is what the context carries. `matching_steps` and
  `exploratory_steps` count only the steps in which at least one module was
  given an observation — the steps in which the episode actually learned
  something — because those are the counts an experiment's termination rules
  are written in terms of.
  """

  alias Monty.Attention.AttentionSystem.NoopAttentionSystem
  alias Monty.Experiment.MatchCriteria
  alias Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching
  alias Monty.Frameworks.Models.GraphMatching.MontyForGraphMatching

  @default_timeout 5_000

  # Monty's own answer for a model whose config names no attention system
  # (`MontyBase.__init__`), and every goal passes through it untouched.
  @default_attention {NoopAttentionSystem, %NoopAttentionSystem{}}

  @enforce_keys [:model_id]
  defstruct model_id: nil,
            model_class: Monty.Runtime.Step,
            sensor_modules: [],
            sensors_step: :auto,
            scheduling: :wait_for_all,
            settle_steps: 0,
            settle_left: nil,
            still_believing: %{},
            reports: %{},
            pending_step: nil,
            learning_modules: [],
            inputs: %{},
            lm_to_lm_vote: nil,
            motor: nil,
            motor_state: nil,
            motor_only?: false,
            combine_votes: &__MODULE__.combine_votes/2,
            attention: @default_attention,
            experiment_mode: nil,
            step_type: :matching,
            min_eval_steps: 0,
            min_train_steps: 0,
            num_exploratory_steps: 0,
            matching_steps: 0,
            exploratory_steps: 0,
            last_processed?: false,
            match_criterion: {MatchCriteria.AnyLMsMatch, %MatchCriteria.AnyLMsMatch{count: 1}},
            terminal_states: %{},
            done?: false,
            vote_timeout: @default_timeout,
            call_timeout: @default_timeout,
            semantic_id_to_label: %{},
            step: 0,
            episode_seed: nil

  @type id :: atom() | String.t()
  @type step_type :: :matching | :exploratory
  @type terminal_state ::
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.terminal_state()
  @type match_criterion :: {module(), term()}
  @type module_spec :: %{
          required(:id) => id(),
          required(:module) => module(),
          required(:state) => term()
        }
  @type input :: %{sensor_modules: [id()], learning_modules: [id()]}

  @type t :: %__MODULE__{
          model_id: id(),
          model_class: module(),
          sensor_modules: [module_spec()],
          learning_modules: [module_spec()],
          inputs: %{optional(id()) => input()},
          lm_to_lm_vote: %{optional(id()) => [id()]} | nil,
          motor: {module(), term()} | nil,
          motor_state: term(),
          motor_only?: boolean(),
          combine_votes: (map(), t() -> map()),
          attention: {module(), term()},
          experiment_mode: Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode(),
          step_type: step_type(),
          min_eval_steps: non_neg_integer(),
          min_train_steps: non_neg_integer(),
          num_exploratory_steps: non_neg_integer(),
          matching_steps: integer(),
          exploratory_steps: integer(),
          last_processed?: boolean(),
          match_criterion: match_criterion(),
          terminal_states: %{optional(id()) => terminal_state()},
          done?: boolean(),
          vote_timeout: timeout(),
          call_timeout: timeout(),
          sensors_step: :auto | :serial | :concurrent,
          scheduling: :wait_for_all | :one_step_behind,
          settle_steps: non_neg_integer(),
          settle_left: nil | non_neg_integer(),
          still_believing: %{optional(id()) => term()},
          reports: %{optional(id()) => {non_neg_integer(), term()}},
          pending_step: nil | %{from: GenServer.from(), epoch: integer(), pending: map()},
          semantic_id_to_label: %{optional(integer()) => String.t()},
          step: non_neg_integer(),
          episode_seed: non_neg_integer() | nil
        }

  @doc """
  How the sensor phase of a step is asked: together, one at a time, or as the
  sensors themselves decide.

  **This port's addition:** Monty never asks — its step loop calls the sensors in
  turn and the order is the answer (`docs/monty-differences.md` §2.28).

  `:concurrent` asks every sensor in one round, so the phase costs its slowest
  sensor instead of the sum — see `step_sensor_modules/4`. Monty's order is
  `:serial`, and that is what `:auto` (the default) answers: the round is a
  deviation this port offers, and a step of `base_10simobj_surf_agent` measured
  3.4–3.5 ms served one at a time against 4.3–4.5 ms served together (this Mac,
  `ex_mujoco`, 8 episodes of 32 steps, two pairs) — one of its two sensors reads
  the view finder and costs nothing, so the round bought a task and no work.

  A round is never taken over a sensor that draws, whichever mode is named: the
  draws would come out in the order the scheduler reached them, which is a
  different episode and not a faster one. `:concurrent` therefore answers
  `:serial` for a set of sensors in which one draws.
  """
  @spec sensors_step(t()) :: :serial | :concurrent
  def sensors_step(%__MODULE__{sensors_step: :serial}), do: :serial

  def sensors_step(%__MODULE__{sensors_step: :concurrent, sensor_modules: modules}) do
    if Enum.any?(modules, &draws?/1), do: :serial, else: :concurrent
  end

  def sensors_step(%__MODULE__{}), do: :serial

  # A module that does not implement the callback was written before it existed;
  # a sensor nobody has described is assumed to draw, which costs its run the
  # speed and never its numbers.
  defp draws?(%{module: module, state: state}) do
    function_exported?(module, :draws_from_stream?, 1) and module.draws_from_stream?(state)
  end

  @doc "Builds the coordinator state from a model spec."
  @spec new(map()) :: t()
  def new(options) do
    learning_modules = Map.fetch!(options, :learning_modules)
    sm_to_lm = Map.get(options, :sm_to_lm, %{})
    lm_to_lm = Map.get(options, :lm_to_lm, %{})

    inputs =
      Map.new(learning_modules, fn lm ->
        {lm.id,
         %{
           sensor_modules: Map.get(sm_to_lm, lm.id, []),
           learning_modules: Map.get(lm_to_lm, lm.id, [])
         }}
      end)

    %__MODULE__{
      model_id: Map.fetch!(options, :model_id),
      model_class: Map.get(options, :model_class, Monty.Runtime.Step),
      sensor_modules: Map.get(options, :sensor_modules, []),
      sensors_step: Map.get(options, :sensors_step, :auto),
      scheduling: Map.get(options, :scheduling, :wait_for_all),
      settle_steps: Map.get(options, :settle_steps, 0),
      settle_left: nil,
      still_believing: %{},
      reports: %{},
      pending_step: nil,
      learning_modules: learning_modules,
      inputs: inputs,
      lm_to_lm_vote: Map.get(options, :lm_to_lm_vote),
      motor: Map.get(options, :motor),
      motor_state: options |> Map.get(:motor) |> motor_state(),
      motor_only?: options |> Map.get(:motor) |> motor_only?(),
      combine_votes: Map.get(options, :combine_votes, &__MODULE__.combine_votes/2),
      attention: Map.get(options, :attention, @default_attention),
      experiment_mode: Map.get(options, :experiment_mode),
      min_eval_steps: Map.get(options, :min_eval_steps, 0),
      min_train_steps: Map.get(options, :min_train_steps, 0),
      num_exploratory_steps: Map.get(options, :num_exploratory_steps, 0),
      match_criterion: Map.get(options, :match_criterion, default_match_criterion()),
      vote_timeout: Map.get(options, :vote_timeout, @default_timeout),
      call_timeout: Map.get(options, :call_timeout, @default_timeout),
      semantic_id_to_label: Map.get(options, :semantic_id_to_label, %{})
    }
  end

  # Monty's `is_motor_only_step` reads the motor system, so the flag a run starts
  # with is the motor system's too — and a surface policy's is true, which is why
  # every episode of his recording has its first percept at step 4 rather than at
  # step 1 (`Monty.Frameworks.Models.MotorPolicies.SurfacePolicy`).
  defp motor_only?(nil), do: false
  defp motor_only?({module, motor_state}), do: module.motor_only_step(motor_state)

  # Monty's model has no criterion of its own: an experiment always sets one
  # before the first episode. With no experiment, "the module recognised
  # something" is the honest default — it is what a single-module run means,
  # and it never ends an episode that concluded nothing.
  defp default_match_criterion, do: MatchCriteria.default()

  @doc """
  Monty's default vote routing: a receiver gets the votes of the modules wired
  to it by `lm_to_lm_vote_matrix`, mounted in the frame of its own sensor.

  Two calculations, told apart by the shape of a vote exactly as Monty tells them
  apart (`isinstance(votes_per_lm[0], set)` in `_combine_votes`): a graph module
  names the objects it ruled out and the answer is their union
  (`...GraphMatching.MontyForGraphMatching.combine_votes/2`), while an evidence
  module names the hypotheses it still believes and the answer is that vote moved
  into the receiver's frame
  (`...EvidenceMatching.Model.MontyForEvidenceGraphMatching.combine_votes/2`).
  Reading the shape rather than the config's model class is what lets one runtime
  step either family — and a run of the graph-matching family used to crash on
  its first vote round, because the union was never written.
  """
  @spec combine_votes(map(), t()) :: map()
  def combine_votes(votes, %__MODULE__{lm_to_lm_vote: lm_to_lm_vote}) do
    if graph_votes?(votes) do
      MontyForGraphMatching.combine_votes(votes, lm_to_lm_vote)
    else
      MontyForEvidenceGraphMatching.combine_votes(votes, lm_to_lm_vote)
    end
  end

  # A vote is a set when the family rules objects out. A round in which every
  # module was silent says nothing about which family it is, and both
  # calculations answer an empty map for it, so silence is read as the evidence
  # family — the shape that carries the frame arithmetic — and costs nothing.
  defp graph_votes?(votes) when map_size(votes) == 0, do: false

  defp graph_votes?(votes) do
    answers = votes |> Map.values() |> Enum.reject(&is_nil/1)
    answers != [] and Enum.all?(answers, &is_struct(&1, MapSet))
  end

  @doc """
  Monty's `_pass_goals` tail: the attention system judges the goals against the
  grid it has learned, and what it answers is what the motors are given.

  Answers the state with the system as this step left it — a system that keeps a
  grid has to be put back, or every step would start from an empty one — and the
  goals worth pursuing.
  """
  @spec step_attention(t(), [Monty.Cmp.Goal.t()], [Monty.Cmp.AttentionRegion.t()]) ::
          {t(), [Monty.Cmp.Goal.t()]}
  def step_attention(%__MODULE__{attention: {module, system}} = state, goals, regions) do
    {system, goals} = module.step(system, goals, regions)
    {%{state | attention: {module, system}}, goals}
  end

  @doc "Monty's `MontyBase.reset` does this too: an episode starts with attention empty."
  @spec reset_attention(t()) :: t()
  def reset_attention(%__MODULE__{attention: {module, system}} = state) do
    %{state | attention: {module, module.reset(system)}}
  end

  defp motor_state(nil), do: nil
  defp motor_state({_module, state}), do: state
end
