defmodule Monty.Runtime.Step.State do
  @moduledoc """
  What a step coordinator needs to know between steps, with the wiring
  normalised once at start.

  Monty's connection matrices (`sm_to_lm_matrix`, `lm_to_lm_matrix`,
  `lm_to_lm_vote_matrix`) are lists indexed by module position in Python; here
  they arrive as maps keyed by module id. This struct inverts them once — for
  every learning module, which sensors feed it and which modules feed it from
  above — so the step loop reads a plain map instead of defensive lookups on
  every phase.
  """

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
            vote_timeout: @default_timeout,
            call_timeout: @default_timeout,
            step: 0

  @type id :: atom() | String.t()
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
      vote_timeout: Map.get(options, :vote_timeout, @default_timeout),
      call_timeout: Map.get(options, :call_timeout, @default_timeout)
    }
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
