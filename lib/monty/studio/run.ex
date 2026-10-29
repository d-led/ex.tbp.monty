defmodule Monty.Studio.Run do
  @moduledoc """
  A run of the experiment you just looked at.

  The setup decides the topology; this starts it as supervised processes and
  steps the clock, one timestep per call. It is deliberately not a GenServer:
  the caller owns the clock (a page, a test, an Oban job), and a run is a value
  you pass around rather than a process you have to ask.

  What comes back from `step/2` is the coordinator's report for one timestep —
  percepts, learning-module inputs, votes, goals, actions — and what a page
  shows while the run is happening. `Monty.Studio.Summary` turns the collected
  reports into what a page shows after it.
  """

  alias Monty.Runtime.Model
  alias Monty.Simulators.Synthetic.Environment
  alias Monty.Studio.Setup

  @default_steps 12

  @enforce_keys [:model_id, :setup, :environment]
  defstruct [:model_id, :setup, :environment, :steps, step: 0, pending_actions: []]

  @type t :: %__MODULE__{
          model_id: String.t(),
          setup: Setup.t(),
          environment: Environment.t(),
          steps: pos_integer(),
          step: non_neg_integer(),
          pending_actions: [Monty.Frameworks.Actions.Action.t()]
        }

  @doc """
  Starts a model for an experiment.

  Options: `:steps` (how many timesteps this run is for, used for the
  controller's progress), `:model_id`.
  """
  @spec start(Setup.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%Setup{} = setup, opts \\ []) do
    model_id =
      Keyword.get_lazy(opts, :model_id, fn -> "studio-#{System.unique_integer([:positive])}" end)

    spec = Setup.model_spec(setup, model_id)

    case DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec}) do
      {:ok, _pid} ->
        {:ok,
         %__MODULE__{
           model_id: model_id,
           setup: setup,
           # The world starts where an episode starts, not where the last one
           # left it: a run is an episode.
           environment: Environment.new(Setup.sensor_ids(setup)),
           steps: Keyword.get(opts, :steps, @default_steps)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs one timestep, returning the report and the advanced run.

  The world is stepped with the actions the model chose on the *previous* step,
  and the report's observations come from *this* one: Monty's `Interface.step/1`
  hands the environment the actions it was given last time, and the first step
  of an episode is taken where the sensors already are.

  A failing module surfaces as an exit from the coordinator rather than a
  returned error: a step either produced a report or the run itself is broken,
  and pretending otherwise here would only move the decision.
  """
  @spec step(t()) :: {:ok, map(), map(), t()}
  def step(%__MODULE__{model_id: model_id, setup: setup, step: step} = run) do
    {observations, proprioceptive_state, environment} =
      Environment.step(run.environment, run.pending_actions)

    ctx = %{Monty.Context.new(seed(setup)) | step: step}

    {:ok, actions, info} = Model.step(model_id, observations, proprioceptive_state, ctx)

    # The observations come back with the report so a page can show what the
    # modules saw, not just what they did with it.
    {:ok, info, observations,
     %{run | step: step + 1, environment: environment, pending_actions: actions}}
  end

  @doc "Whether the run has used its steps."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{step: step, steps: steps}), do: step >= steps

  @doc "Stops the run's processes; safe to call twice."
  @spec stop(t()) :: :ok | {:error, :not_found}
  def stop(%__MODULE__{model_id: model_id}) do
    Monty.Runtime.Model.stop(model_id)
  end

  @doc "How many steps a run of this experiment takes by default."
  @spec default_steps() :: pos_integer()
  def default_steps, do: @default_steps

  defp seed(%Setup{seed: seed}) when is_integer(seed), do: seed
  defp seed(_setup), do: 0
end
