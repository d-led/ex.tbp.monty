# One line per episode and learning module: what the episode showed, what the
# module concluded, and in how many steps — the columns Monty's `eval_stats.csv`
# keeps, printed so a port run and a Monty run of the same config can be read
# against each other.
#
#     MIX_ENV=test mix run --no-start scripts/probe_parity_ladder.exs \
#       base_infer_cows_small_compositional 11
#
# The episodes are stepped here rather than through `mix monty.run` because a
# run's own record needs the studio's database, and this question — did episode
# *n* conclude the way Monty's episode *n* did — is answerable from the run's
# statistics alone. `episode_seed` is what joins the two: both derive it from the
# config's own seed and the episode's index, so it is the same number on both
# sides when the episode is the same episode.
:logger.set_primary_config(:level, :warning)
{:ok, _} = Application.ensure_all_started(:ex_tbp_monty)

defmodule ParityLadder do
  @moduledoc "Monty's per-episode columns, from a port run that was stepped by hand."

  def run(name, episodes) do
    {:ok, opened} =
      Monty.Studio.open(name,
        conf_dir: Monty.Config.Source.conf_dirs(),
        world_simulator: :ex_mujoco
      )

    setup = opened.setup
    experiment = Monty.Studio.Setup.experiment_class(setup)
    memories = Monty.Studio.Setup.memories(setup)

    IO.puts("episode · seed · showed · module · concluded · steps · detected")

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

  # A recognition episode is a few hundred steps; the ceiling guards a config
  # that never concludes at all.
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
    showed = object_of(run) || "?"

    for module <- sorted(state.learning_modules) do
      id = module_id(module)
      conclusion = Map.get(state.terminal_states, id, "no conclusion")

      IO.puts(
        "#{index + 1} · #{run.episode_seed} · #{showed} · #{id} · #{conclusion} · " <>
          "#{run.step} · #{detected(module)}"
      )
    end
  end

  defp sorted(modules), do: Enum.sort_by(modules, &module_id/1)

  defp module_id(module), do: Map.get(module, :id) || Map.get(module, "id") || "?"

  defp detected(module) do
    inner = Map.get(module, :state) || Map.get(module, :module)
    if is_map(inner), do: to_string(Map.get(inner, :detected_object) || "—"), else: "—"
  end

  defp object_of(run) do
    case Monty.Studio.Run.target(run) do
      %{"object_name" => object} -> object
      _no_object -> nil
    end
  end
end

[experiment, episodes] = System.argv()
ParityLadder.run(experiment, String.to_integer(episodes))
