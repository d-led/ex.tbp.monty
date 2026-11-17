# Does asking a step's sensors together buy time, and does it decide the same?
#
#     MIX_ENV=dev mix run --no-start scripts/probe_sensor_rounds.exs tutorial/dist_agent_5lm_2obj_eval 3
#
# A step asks its sensors through `Step.step_sensor_modules/4`, which has two
# rounds: one call after another — Monty's, and the only one available while a
# sensor draws from the episode's stream — and one round for the whole phase
# (`Monty.Runtime.Step.State.sensors_step/1`, which the sensors themselves
# decide). This runs the *same* episode both ways and prints both halves of the
# question:
#
#   * the time: mean model step, taken from the info each step answers with;
#   * the answer: the step count, and every step's percepts, actions and
#     terminal states, compared one to one.
#
# The comparison is the point. A faster round that decided something else would
# be a different experiment, so an arm that disagrees with its sibling is
# reported as loudly as the number is.
:logger.set_primary_config(:level, :warning)
{:ok, _} = Application.ensure_all_started(:ex_tbp_monty)

defmodule SensorRounds do
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
      serial = arm(setup, memories, episode, :serial)
      concurrent = arm(setup, memories, episode, :concurrent)

      report(episode, serial, concurrent)
    end
  end

  # One episode stepped to its conclusion, answering what it decided and what it
  # cost. The round is a property of the model spec, so the two arms are two runs
  # of the same episode: same setup, same memory, same episode seed.
  defp arm(setup, memories, episode, round) do
    {:ok, run} =
      Monty.Studio.Run.start(Monty.Studio.Setup.with_phase(setup, :eval),
        steps: Monty.Studio.Run.cap(setup),
        episode: episode,
        epoch: 0,
        mode: :eval,
        memory: memories,
        first_seen: %{},
        sensors_step: round
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

    %{round: round, steps: steps, infos: infos}
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
  # arms are allowed to differ in.
  defp decided(%{step: step, percept_ids: ids, actions: actions, terminal_states: states}) do
    {step, {ids, actions, states}}
  end

  defp report(episode, serial, concurrent) do
    answers = Map.new(concurrent.infos, &decided/1)

    disagreements =
      for {step, answer} <- Enum.map(serial.infos, &decided/1),
          Map.get(answers, step) != answer,
          do: step

    # A step's own duration, in milliseconds, from the info it answered with.
    mean_ms = fn arm ->
      arm.infos
      |> Enum.map(& &1.duration_us)
      |> Enum.sum()
      |> Kernel./(max(arm.steps, 1))
      |> Kernel./(1000)
    end

    IO.puts(
      "\nepisode #{episode + 1}: serial #{serial.steps} steps, model " <>
        "#{fmt(mean_ms.(serial))} ms a step; concurrent #{concurrent.steps} steps, model " <>
        "#{fmt(mean_ms.(concurrent))} ms a step " <>
        "(#{fmt(mean_ms.(serial) / max(mean_ms.(concurrent), 0.001))}x)"
    )

    case disagreements do
      [] ->
        IO.puts("  every step decided the same: percepts, actions and terminal states")

      steps ->
        IO.puts(
          "  DISAGREED on #{length(steps)} of #{serial.steps} steps: #{inspect(Enum.take(steps, 8))}"
        )
    end
  end

  defp fmt(number), do: :erlang.float_to_binary(number * 1.0, decimals: 1)
end

[name | rest] = System.argv()
episodes = rest |> List.first("1") |> String.to_integer()

SensorRounds.run(name, episodes)
