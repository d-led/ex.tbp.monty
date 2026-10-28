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

  @default_timeout 5_000

  @enforce_keys [:model_id]
  defstruct model_id: nil,
            sensor_modules: [],
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
            step: 0

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
          step: non_neg_integer()
        }

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
      sensor_modules: Map.get(options, :sensor_modules, []),
      learning_modules: learning_modules,
      inputs: inputs,
      lm_to_lm_vote: Map.get(options, :lm_to_lm_vote),
      motor: Map.get(options, :motor),
      motor_state: options |> Map.get(:motor) |> motor_state(),
      combine_votes: Map.get(options, :combine_votes, &__MODULE__.combine_votes/2),
      attention: Map.get(options, :attention, &__MODULE__.all_goals/2),
      experiment_mode: Map.get(options, :experiment_mode),
      min_eval_steps: Map.get(options, :min_eval_steps, 0),
      min_train_steps: Map.get(options, :min_train_steps, 0),
      num_exploratory_steps: Map.get(options, :num_exploratory_steps, 0),
      match_criterion: Map.get(options, :match_criterion, default_match_criterion()),
      vote_timeout: Map.get(options, :vote_timeout, @default_timeout),
      call_timeout: Map.get(options, :call_timeout, @default_timeout)
    }
  end

  # Monty's model has no criterion of its own: an experiment always sets one
  # before the first episode. With no experiment, "the module recognised
  # something" is the honest default — it is what a single-module run means,
  # and it never ends an episode that concluded nothing.
  defp default_match_criterion do
    {MatchCriteria.AnyLMsMatch, %MatchCriteria.AnyLMsMatch{count: 1}}
  end

  @doc """
  Monty's default vote routing: a receiver gets the votes of the modules wired
  to it by `lm_to_lm_vote_matrix`.
  """
  @spec combine_votes(map(), t()) :: map()
  def combine_votes(votes, %__MODULE__{lm_to_lm_vote: lm_to_lm_vote}) do
    Map.new(lm_to_lm_vote, fn {receiver, sources} ->
      {receiver, Enum.map(sources, &Map.fetch!(votes, &1))}
    end)
  end

  @doc "Monty's `NoopAttentionSystem`: every proposed goal passes."
  @spec all_goals([Monty.Cmp.Goal.t()], [Monty.Cmp.AttentionRegion.t()]) :: [Monty.Cmp.Goal.t()]
  def all_goals(goals, _regions), do: goals

  defp motor_state(nil), do: nil
  defp motor_state({_module, state}), do: state
end
