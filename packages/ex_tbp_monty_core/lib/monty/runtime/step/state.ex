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

  alias Monty.Experiment.MatchCriteria
  alias Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching
  alias Monty.Frameworks.Models.GraphMatching.MontyForGraphMatching

  @default_timeout 5_000

  @enforce_keys [:model_id]
  defstruct model_id: nil,
            model_class: Monty.Runtime.Step,
            sensor_modules: [],
            sensors_step: :auto,
            scheduling: :barrier,
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
            attention: &__MODULE__.all_goals/2,
            experiment_mode: nil,
            step_type: :matching,
            min_eval_steps: 0,
            min_train_steps: 0,
            num_exploratory_steps: 0,
            matching_steps: 0,
            exploratory_steps: 0,
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
          attention: ([Monty.Cmp.Goal.t()], [Monty.Cmp.AttentionRegion.t()] ->
                        [Monty.Cmp.Goal.t()]),
          experiment_mode: Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode(),
          step_type: step_type(),
          min_eval_steps: non_neg_integer(),
          min_train_steps: non_neg_integer(),
          num_exploratory_steps: non_neg_integer(),
          matching_steps: integer(),
          exploratory_steps: integer(),
          match_criterion: match_criterion(),
          terminal_states: %{optional(id()) => terminal_state()},
          done?: boolean(),
          vote_timeout: timeout(),
          call_timeout: timeout(),
          sensors_step: :auto | :serial | :concurrent,
          scheduling: :barrier | :lagged,
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
  sensor instead of the sum — see `step_sensor_modules/4`. It is only safe while
  none of them draws from the episode's stream, which is why `:auto` (the
  default) answers `:concurrent` for a set of sensors that draw nothing and
  `:serial` for a set in which one does. A run that wants Monty's round either
  way asks for `:serial`; a run that wants the round and knows its sensors do
  not draw asks for `:concurrent`, and gets it even then.

  `:auto` is the interesting one: every `raw0` camera — the presets the shipped
  experiments run — holds `NoMessageNoise`, so a five-camera experiment is
  concurrent by construction and its numbers cannot move, because nothing in the
  phase reads the stream it would have shared.
  """
  @spec sensors_step(t()) :: :serial | :concurrent
  def sensors_step(%__MODULE__{sensors_step: :serial}), do: :serial

  def sensors_step(%__MODULE__{sensors_step: :concurrent}), do: :concurrent

  def sensors_step(%__MODULE__{sensor_modules: modules}) do
    if Enum.any?(modules, &draws?/1), do: :serial, else: :concurrent
  end

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
      scheduling: Map.get(options, :scheduling, :barrier),
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
      attention: Map.get(options, :attention, &__MODULE__.all_goals/2),
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

  @doc "Monty's `NoopAttentionSystem`: every proposed goal passes."
  @spec all_goals([Monty.Cmp.Goal.t()], [Monty.Cmp.AttentionRegion.t()]) :: [Monty.Cmp.Goal.t()]
  def all_goals(goals, _regions), do: goals

  defp motor_state(nil), do: nil
  defp motor_state({_module, state}), do: state
end
