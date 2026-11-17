# What each recognition episode concluded, in the terms that make it checkable:
# the dog the episode showed, the graph the module settled on, and the object that
# graph was built from.
#
#     MIX_ENV=test mix run --no-start scripts/probe_recognitions.exs dogs/inference_surf_supervised_4rot 24
#
# The two halves of a verdict travel apart in a run's own log: `terminal_states`
# says whether the episode concluded, and `detected_object` names the graph — which
# is only the dog's name when the memory was built by supervised pretraining
# (`docs/training.md` §9). This prints both, per episode, so "eight of eight match,
# seven named correctly" is a line somebody can count rather than a claim.
:logger.set_primary_config(:level, :info)
{:ok, _} = Application.ensure_all_started(:ex_tbp_monty)

defmodule Recognitions do
  @doc """
  Steps `episodes` recognition episodes of `name` and prints what each concluded.

  The episodes are stepped here rather than through `mix monty.run` because a
  run's log carries the verdict without the name, and it is the name that decides
  whether a `match` was right.
  """
  def run(name, episodes) do
    conf = [Path.expand("priv/monty_experiments/conf"), Monty.Config.Source.conf_dir()]
    {:ok, opened} = Monty.Studio.open(name, conf_dir: conf, world_simulator: :ex_mujoco)
    setup = opened.setup
    experiment = Monty.Studio.Setup.experiment_class(setup)
    memories = Monty.Studio.Setup.memories(setup)

    for index <- 0..(episodes - 1) do
      {:ok, run} =
        Monty.Studio.Run.start(Monty.Studio.Setup.with_phase(setup, :eval),
          steps: Monty.Studio.Run.cap(setup),
          episode: index,
          epoch: 0,
          mode: :eval,
          memory: memories,
          first_seen: %{}
        )

      {:ok, state} = experiment.pre_episode(%{run: run}, index, object_of(run), callbacks())
      run = step(state.run, 0)

      print(index, run)
      Monty.Studio.Run.stop(run)
    end
  end

  defp object_of(run) do
    case Monty.Studio.Run.target(run) do
      %{"object_name" => object} -> object
      _no_object -> nil
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

  # A recognition episode of this port is a few hundred steps; the ceiling is only
  # a guard against a config that never concludes at all.
  defp step(run, n) do
    if Monty.Studio.Run.finished?(run) or n > 8000 do
      run
    else
      {:ok, _info, _observations, next} = Monty.Studio.Run.step(run)
      step(next, n + 1)
    end
  end

  defp print(index, run) do
    state = Monty.Studio.Run.statistics(run, &Monty.Studio.Logging.projection/1)
    said = Map.get(state.terminal_states, "learning_module_0")

    for module <- state.learning_modules do
      inner = Map.get(module, :state) || Map.get(module, :module)
      detected = is_map(inner) && Map.get(inner, :detected_object)
      targets = is_map(inner) && Map.get(inner, :graph_id_to_target)

      IO.puts(
        "episode #{index + 1}: showed #{object_of(run) || "?"} · #{inspect(said)} · " <>
          "detected #{inspect(detected)} of #{inspect(target_of(detected, targets))}"
      )
    end
  end

  defp target_of(nil, _targets), do: nil
  defp target_of(graph, targets) when is_map(targets), do: Map.get(targets, graph)
  defp target_of(_graph, _targets), do: nil
end

[name | rest] = System.argv()
episodes = rest |> List.first("8") |> String.to_integer()

Recognitions.run(name, episodes)
