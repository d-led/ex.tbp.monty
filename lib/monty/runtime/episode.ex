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

  ## Why the step limit is a policy

  Monty's experiment does not stop an episode by counting steps; it asks a
  recognition policy (`MaxTotalSteps`, `MinEvalMaxTotalSteps`,
  `ObjectRecognition`, and `AnyPolicy` over them), and the policy also decides
  whether undecided modules should be timed out and whether the episode should
  start exploring. So this loop asks the same question, through the same
  policies: `:max_steps` is sugar for `MaxTotalSteps`, and `:policy` takes any
  of them.
  """

  require Logger

  alias Monty.Context
  alias Monty.Experiment.RecognitionPolicy

  alias Monty.Experiment.RecognitionPolicy.{
    AnyPolicy,
    MaxTotalSteps,
    MontyIsDone,
    RecognitionCounter
  }

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
    * `:policy` — a recognition policy, as `{module, state}`; defaults to
      `MaxTotalSteps` over `:max_steps`;
    * `:max_steps` — how many steps the episode may take before it is timed out;
    * `:seed` — the episode's seed, carried in the context.

  A time-out is not a failure: it is the experiment giving up on an episode, and
  the model is told so, so its columns are not left open.
  """
  @spec run(atom() | String.t(), environment(), keyword()) :: result()
  def run(model_id, environment, options \\ []) do
    mode = Keyword.get(options, :mode, :eval)
    policy = policy(options)
    ctx = Context.new(Keyword.get(options, :seed, 0))

    :ok = Model.reset_episode(model_id)
    :ok = Model.set_experiment_mode(model_id, mode)

    result =
      step_until_done(
        model_id,
        environment,
        ctx,
        policy,
        RecognitionCounter.new(mode),
        %{steps: 0, infos: []}
      )

    if mode == :train, do: :ok = Model.update_ltm(model_id)

    # The conclusions are read from the model rather than from the last step's
    # report: a time-out happens after that report, and is part of the episode.
    Map.put(result, :terminal_states, Model.state(model_id).terminal_states)
  end

  # The default is Monty's own: `MontyIsDone`, unioned with the step ceiling the
  # experiment allows. `:max_steps` is not a second mechanism — it is that
  # ceiling, which is exactly `MaxTotalSteps`.
  defp policy(options) do
    case Keyword.fetch(options, :policy) do
      {:ok, policy} ->
        policy

      :error ->
        {:ok, done} = MontyIsDone.new()

        {:ok, ceiling} =
          MaxTotalSteps.new(max_total_steps: Keyword.get(options, :max_steps, @default_max_steps))

        {:ok, policy} = AnyPolicy.new(policies: [done, ceiling])
        policy
    end
  end

  # Monty's `while not complete(count)`: ask the policy, do both things it can
  # ask for besides stopping, and only then take another step. Applying the
  # reactions before the check is what makes `start_exploring` reach the next
  # step, and what lets a policy time the lagging modules out and still end.
  defp step_until_done(model_id, environment, ctx, policy, counter, run) do
    decision = RecognitionPolicy.call(policy, view(model_id), counter)
    apply_reactions(model_id, decision)

    if decision.is_done do
      finish(decision, run)
    else
      step_once(model_id, environment, ctx, policy, counter, run)
    end
  end

  defp step_once(model_id, environment, ctx, policy, counter, run) do
    {observations, proprioceptive_state} = environment.(last_actions(run))

    {:ok, actions, info} = Model.step(model_id, observations, proprioceptive_state, ctx)

    step_until_done(
      model_id,
      environment,
      ctx,
      policy,
      RecognitionCounter.count_step(counter, info.inputs != %{}, info.step_type == :exploratory),
      %{steps: run.steps + 1, infos: [info | run.infos], last_actions: actions}
    )
  end

  # The policy's own word for the ending: `time_out_lms` is what Monty calls
  # `deal_with_time_out`, the ending an episode gets when it ran out of steps
  # rather than recognising anything.
  defp finish(decision, run) do
    if decision.time_out_lms do
      Logger.warning("episode timed out after #{run.steps} steps")
      %{steps: run.steps, done?: true, timed_out?: true, infos: Enum.reverse(run.infos)}
    else
      Logger.debug("episode ended after #{run.steps} steps")
      %{steps: run.steps, done?: true, timed_out?: false, infos: Enum.reverse(run.infos)}
    end
  end

  # Monty's `_recognition_complete`: the two things a policy can ask for besides
  # stopping.
  defp apply_reactions(model_id, decision) do
    if decision.start_exploring, do: :ok = Model.switch_to_exploratory_step(model_id)
    if decision.time_out_lms, do: :ok = Model.time_out(model_id)
  end

  # The four things a policy may read off the model (`docs/monty-bugs.md` §2.17).
  defp view(model_id), do: Model.status(model_id)

  # Monty's first step is taken with no action: the environment is asked for
  # what the sensors see where they already are.
  defp last_actions(%{last_actions: actions}), do: actions
  defp last_actions(%{}), do: []
end
