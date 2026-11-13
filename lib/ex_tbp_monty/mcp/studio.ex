defmodule ExTbpMonty.Mcp.Studio do
  @moduledoc """
  What this deployment is, and how it runs things.

  Every question a caller cannot answer from a config file lives here: how many
  experiments there are, what state the runs are in, how many can be in flight at
  once, whether the world is Monty's or this port's stand-in, and whether the
  data and models are on disk. An assistant with this tool needs no shell: the
  numbers and their caveats are one call away.

  The parallel figure is read from the queue rather than from the config, because
  the run page changes the queue's limit while the queue drains — the config
  value is where it started, not where it is.
  """

  alias Monty.Prerequisites
  alias Monty.Studio.{Artifacts, Catalog, RunHistory, Storage}

  @queue :studio

  @doc """
  The deployment as a value: counts, parallelism, world, storage, prerequisites.
  """
  @spec describe() :: map()
  def describe do
    %{
      experiments: length(Catalog.experiments()),
      runs: RunHistory.counts(),
      parallel: parallel(),
      world: world(),
      storage: storage(),
      prerequisites: prerequisites()
    }
  end

  # One run is one *part* of the experiment: the studio divides it — evaluation
  # by episode, training by object (`Monty.Studio.Partition`) — and steps each
  # part on its own, which is what makes a run's page about one stretch of the
  # experiment rather than about all of it.
  #
  # The limit comes from the running queue, because the run page changes it while
  # the queue drains — the configured value is where it started, not where it is.
  # A process with no queue up (a Mix task, a test) answers that, and still says
  # what the limit would be rather than answering nothing.
  defp parallel do
    case Oban.check_queue(queue: @queue) do
      %{} = state -> live_parallelism(state)
      nil -> configured_parallelism()
    end
  end

  defp live_parallelism(state) do
    %{
      episodes_at_once: state.limit,
      live?: true,
      running_now: running_count(state.running),
      paused?: state.paused == true,
      one_part_per_run: true,
      how: how(),
      monty_equivalent: monty_equivalent()
    }
  end

  defp configured_parallelism do
    %{
      episodes_at_once: configured_limit(),
      live?: false,
      running_now: 0,
      paused?: false,
      one_part_per_run: true,
      how: how() <> " (This process has no queue running, so nothing is executing here.)",
      monty_equivalent: monty_equivalent()
    }
  end

  # `queues: false` is how a test run says "no queue in this process"; there is
  # then no limit to report, and nil says that rather than inventing one.
  defp configured_limit do
    case Application.get_env(:ex_tbp_monty, Oban, []) do
      config when is_list(config) ->
        case Keyword.get(config, :queues) do
          queues when is_list(queues) -> Keyword.get(queues, @queue)
          _no_queues -> nil
        end

      _not_a_list ->
        nil
    end
  end

  defp how do
    "a run is a job on the :studio queue, and the queue's limit is how many run at once. " <>
      "The run page's \"in parallel\" selector divides the experiment into that many parts " <>
      "— evaluation by episode, training by object — queues one run each, and sets the " <>
      "limit to the same number."
  end

  defp monty_equivalent,
    do:
      "Monty's run_parallel.py: one config per part, evaluation by episode and training by object"

  # `running` is the producer's list of executing job ids, not a count.
  defp running_count(ids), do: length(ids)

  defp world do
    # `||`, not `Application.get_env/3`'s default: a key that exists and is nil is
    # "nothing configured", which is every deployment — there is no
    # `world_simulator` in `config/config.exs` on purpose (`docs/simulator-port.md`).
    mode = Application.get_env(:ex_tbp_monty, :world_simulator) || :mujoco

    %{
      mode: to_string(mode),
      peer_interpreter: System.get_env("MONTY_PYTHON"),
      note:
        if(mode == :synthetic,
          do:
            "a run steps this port's own scene; Monty's simulator in an external process is " <>
              "the default, and `monty_run_experiment` with `world: \"monty\"` (or the run " <>
              "page's selector) chooses it. `MONTY_PYTHON` is the interpreter it runs in",
          else:
            "the simulator runs in an external process — the experiment's own engine — " <>
              "unless the run chooses the stand-in"
        )
    }
  end

  # The two places a run adds to the disk: what it leaves behind, and what it had
  # to download first. In a container both are the one volume mounted under the
  # application's home; in a checkout they are `priv/` and the roots the
  # environment variables name, which need not be the same disk — so the answer
  # is per place rather than one figure for "the disk".
  defp storage do
    [
      {"run artifacts and logs", Artifacts.root()},
      {"prerequisite downloads", Prerequisites.root_path("MONTY_DATA")}
    ]
    |> Enum.map(fn {what, path} -> Map.put(Storage.usage(path), :what, what) end)
  end

  defp prerequisites do
    Prerequisites.all()
    |> Enum.map(fn prerequisite ->
      %{
        id: prerequisite.id,
        title: Map.get(prerequisite, :title, prerequisite.id),
        present?: Prerequisites.present?(prerequisite),
        path: Prerequisites.target_path(prerequisite)
      }
    end)
  end
end
