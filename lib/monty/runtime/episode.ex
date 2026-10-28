defmodule Monty.Runtime.Episode do
  @moduledoc """
  One episode: a model stepped against an environment until it concludes.

  Mirrors the episode loop of `MontyExperiment.run_episode_steps`
  (`frameworks/experiments/monty_experiment.py`), without the experiment's data
  loading, epochs and loggers — those belong to whatever is running episodes,
  and this module is what is left when they are taken away:

    * clear the model's short-term memory and tell it whether the episode trains
      or evaluates;
    * step the environment and the model until the model says it is done, or
      until the step limit the experiment allows;
    * hand a training episode to long-term memory.

  ## The environment

  An episode takes a function from the *actions of the previous step* to
  `{observations, proprioceptive_state}` — Monty's `Interface.step/1`. That is
  all the model needs of a world, so a recorded stream of observations, a
  simulator, and a Python environment behind a port are all the same thing here.

  ## Why the step limit is outside the model

  The model ends an episode when its columns agree, and a model that never
  agrees would run for ever. Monty's experiment wraps the model's own decision
  in a policy that also counts steps (`MaxTotalSteps`, `MinEvalMaxTotalSteps`);
  this is that limit, kept where the experiment's limits belong.
  """

  require Logger

  alias Monty.Context
  alias Monty.Runtime.Model

  @default_max_steps 1_000

  @type environment :: ([map()] -> {map(), map()})
  @type mode :: Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode()

  @type result :: %{
          steps: non_neg_integer(),
          done?: boolean,
          timed_out?: boolean,
          terminal_states: %{optional(atom()) => Monty.Runtime.Step.State.terminal_state()},
          infos: [map()]
        }

  @doc """
  Runs one episode of `model_id` against `environment`.

  Options:

    * `:mode` — `:train` or `:eval`; training writes to memory at the end;
    * `:max_steps` — how many steps the episode may take before it is timed out;
    * `:seed` — the episode's seed, carried in the context.

  A time-out is not a failure: it is the experiment giving up on an episode, and
  the model is told so, so its columns are not left open.
  """
  @spec run(atom() | String.t(), environment(), keyword()) :: result()
  def run(model_id, environment, options \\ []) do
    mode = Keyword.get(options, :mode, :eval)
    max_steps = Keyword.get(options, :max_steps, @default_max_steps)
    ctx = Context.new(Keyword.get(options, :seed, 0))

    :ok = Model.reset_episode(model_id)
    :ok = Model.set_experiment_mode(model_id, mode)

    result = step_until_done(model_id, environment, ctx, max_steps, %{steps: 0, infos: []})

    if mode == :train, do: :ok = Model.update_ltm(model_id)

    # The conclusions are read from the model rather than from the last step's
    # report: a time-out happens after that report, and is part of the episode.
    Map.put(result, :terminal_states, Model.state(model_id).terminal_states)
  end

  defp step_until_done(model_id, environment, ctx, max_steps, run) do
    cond do
      Model.done?(model_id) ->
        Logger.debug("episode ended after #{run.steps} steps")

        %{steps: run.steps, done?: true, timed_out?: false, infos: Enum.reverse(run.infos)}

      run.steps >= max_steps ->
        Logger.warning("episode timed out after #{run.steps} steps")
        :ok = Model.time_out(model_id)

        %{steps: run.steps, done?: true, timed_out?: true, infos: Enum.reverse(run.infos)}

      true ->
        {observations, proprioceptive_state} = environment.(last_actions(run))

        {:ok, actions, info} =
          Model.step(model_id, observations, proprioceptive_state, ctx)

        step_until_done(model_id, environment, ctx, max_steps, %{
          steps: run.steps + 1,
          infos: [info | run.infos],
          last_actions: actions
        })
    end
  end

  # Monty's first step is taken with no action: the environment is asked for
  # what the sensors see where they already are.
  defp last_actions(%{last_actions: actions}), do: actions
  defp last_actions(%{}), do: []
end
