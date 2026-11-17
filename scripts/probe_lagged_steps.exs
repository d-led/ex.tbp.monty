# Does a lagged step buy time, and what does it decide differently?
#
#     MIX_ENV=dev mix run --no-start scripts/probe_lagged_steps.exs tutorial/dist_agent_5lm_2obj_eval 1
#
# A step is scheduled either way `Monty.Runtime.Step.State.scheduling/1` names
# (`docs/monty-differences.md` §2.30). `:barrier` is Monty's own order: the step
# waits for the modules it handed work to, then runs its vote round. `:lagged` is
# the continuous pipeline: the step hands the epoch over and does not wait, runs
# the round for the epoch before, reads it out of the report each module sent, and
# replies when the last of those reports arrives.
#
# This runs the *same* episode both ways and prints the two answers a scheduling
# change owes:
#
#   * the time — the mean model step and the episode's own wall clock;
#   * the answer — the step count and where the two arms first part. A lagged
#     round's goals are one epoch older than the percepts they move on, so parting
#     is expected; how *far* apart they then go is the price, and the number that
#     decides whether the mode is worth having.
:logger.set_primary_config(:level, :warning)
{:ok, _} = Application.ensure_all_started(:ex_tbp_monty)

defmodule LaggedSteps do
  @ceiling 8_000

  def run(name, episodes) do
    conf = Monty.Config.Source.conf_dirs()
    {:ok, opened} = Monty.Studio.open(name, conf_dir: conf, world_simulator: :ex_mujoco)
    setup = opened.setup
    memories = Monty.Studio.Setup.memories(setup)

    IO.puts(
      "#{name}: #{length(setup.sensors)} sensors, " <>
        "#{episodes} episode#{if episodes == 1, do: "", else: "s"}"
    )

    for episode <- 0..(episodes - 1) do
      barrier = arm(setup, memories, episode, :barrier)
      lagged = arm(setup, memories, episode, :lagged)

      report(episode, barrier, lagged)
    end
  end

  # One episode stepped to its conclusion, answering what it decided and what it
  # cost. The mode is a property of the model spec, so the two arms are two runs
  # of the same episode: same setup, same memory, same episode seed.
  defp arm(setup, memories, episode, scheduling) do
    started_at = System.monotonic_time(:millisecond)

    {:ok, run} =
      Monty.Studio.Run.start(Monty.Studio.Setup.with_phase(setup, :eval),
        steps: Monty.Studio.Run.cap(setup),
        episode: episode,
        epoch: 0,
        mode: :eval,
        memory: memories,
        first_seen: %{},
        scheduling: scheduling
      )

    {:ok, state} =
      Monty.Studio.Setup.experiment_class(setup).pre_episode(
        %{run: run},
        episode,
        object_of(run),
        callbacks()
      )

    {steps, infos} = step(state.run, 0, [])
    Monty.Studio.Run.stop(state.run)

    %{
      scheduling: scheduling,
      steps: steps,
      infos: infos,
      wall_ms: System.monotonic_time(:millisecond) - started_at
    }
  end

  # A recognition episode of this port is a few hundred steps; the ceiling is only
  # a guard against a config that never concludes at all.
  defp step(run, n, infos) do
    if Monty.Studio.Run.finished?(run) or n >= @ceiling do
      {n, Enum.reverse(infos)}
    else
      {:ok, info, _observations, next} = Monty.Studio.Run.step(run)
      step(next, n + 1, [info | infos])
    end
  end

  defp callbacks do
    %{
      pre_episode: fn state, _index, _object, _callbacks -> {:ok, state} end,
      ground_truth: fn %{run: run} = state ->
        :ok = Monty.Studio.Run.set_ground_truth(run)
        {:ok, state}
      end,
      post_episode: fn state, _outcome, _infos -> state end
    }
  end

  defp object_of(run) do
    case Monty.Studio.Run.target(run) do
      %{"object_name" => object} -> object
      _no_object -> nil
    end
  end

  # What a step decided, with the duration taken out — that is the only thing the
  # arms are allowed to differ in without saying so.
  defp decided(%{step: step, percept_ids: ids, actions: actions, terminal_states: states}) do
    {step, {ids, actions, states}}
  end

  defp report(episode, barrier, lagged) do
    answers = Map.new(lagged.infos, &decided/1)

    disagreements =
      for {step, answer} <- Enum.map(barrier.infos, &decided/1),
          Map.get(answers, step) != answer,
          do: step

    mean_ms = fn arm ->
      arm.infos
      |> Enum.map(& &1.duration_us)
      |> Enum.sum()
      |> Kernel./(max(arm.steps, 1))
      |> Kernel./(1000)
    end

    IO.puts(
      "\nepisode #{episode + 1}: barrier #{barrier.steps} steps, model " <>
        "#{fmt(mean_ms.(barrier))} ms a step, #{barrier.wall_ms} ms wall; " <>
        "lagged #{lagged.steps} steps, model #{fmt(mean_ms.(lagged))} ms a step, " <>
        "#{lagged.wall_ms} ms wall " <>
        "(#{fmt(barrier.wall_ms / max(lagged.wall_ms, 1))}x wall, " <>
        "#{fmt(mean_ms.(barrier) / max(mean_ms.(lagged), 0.001))}x model step)"
    )

    case disagreements do
      [] ->
        IO.puts("  every step decided the same: percepts, actions and terminal states")

      steps ->
        IO.puts(
          "  the arms part at step #{Enum.min(steps)}, and disagree on " <>
            "#{length(steps)} of #{barrier.steps} steps"
        )
    end
  end

  defp fmt(number), do: :erlang.float_to_binary(number * 1.0, decimals: 1)
end

[name | rest] = System.argv()
episodes = rest |> List.first("1") |> String.to_integer()

LaggedSteps.run(name, episodes)
