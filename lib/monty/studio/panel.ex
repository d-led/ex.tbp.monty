defmodule Monty.Studio.Panel do
  @moduledoc """
  What Monty's own configuration panel says about a run, in its words.

  The same sentences before a run is started and after it has finished: the
  configuration a page promises is the configuration the record kept, and one
  place that reads the config writes it once. Two pages phrasing the same eight
  facts separately is how a page comes to promise something the run did not do —
  `n_train_epochs` announced as training by one page and skipped by the other,
  because only one of them asked `do_train`.

  Every fact is read from the config, never assumed: an experiment that names
  three train epochs and switches training off says so, and a config that names
  no step limits says it names none instead of showing zero.
  """

  alias Monty.Studio.Setup

  @typedoc "One line of the panel: what it is called, and what the config says."
  @type fact :: {String.t(), String.t()}

  @doc """
  The panel's facts, in the order Monty shows them.

  `seed` is the seed the run is under, which is only the config's own until
  somebody chooses another; `nil` asks for the config's.
  """
  @spec facts(Setup.t(), integer() | nil) :: [fact()]
  def facts(%Setup{} = setup, seed \\ nil) do
    [
      {"sensors", sensor_ids(setup)},
      {"learning modules", learning_module_ids(setup)},
      {"epochs", epochs(setup)},
      {"ported here", ported(setup)},
      {"model", model(setup)},
      {"seed", seed_text(setup, seed)},
      {"training · evaluation", phases(setup)},
      {"episodes, as the config runs them", episodes_planned(setup)},
      {"steps, as the config limits them", budget(setup)}
    ]
  end

  defp sensor_ids(setup), do: Enum.map_join(setup.sensors, ", ", & &1.id)

  defp learning_module_ids(setup), do: Enum.map_join(setup.learning_modules, ", ", & &1.id)

  defp epochs(setup), do: "train #{setup.epochs.train} · eval #{setup.epochs.eval}"

  defp ported(setup) do
    %{implemented: implemented, total: total} = Setup.ported(setup)
    "#{implemented}/#{total}"
  end

  # The memory a run starts from, named the way Monty's own panel names it: the
  # release's directory, not the path to it. An experiment that trains instead
  # of loading says so, because that is a different run.
  defp model(%{model_name_or_path: nil}), do: "trained here"

  defp model(%{model_name_or_path: path}) do
    path
    |> to_string()
    |> Path.split()
    |> Enum.reverse()
    |> Enum.reject(&(&1 in ["pretrained", ""]))
    |> case do
      [name | _rest] -> name
      [] -> "trained here"
    end
  end

  defp seed_text(_setup, seed) when is_integer(seed), do: to_string(seed)

  defp seed_text(%{seed: seed}, _chosen) when is_integer(seed), do: to_string(seed)

  defp seed_text(_setup, _chosen), do: "the config's own"

  # Monty's panel says Training and Evaluation separately, because an experiment
  # can do one without the other. The port reads the config's own two switches:
  # `n_train_epochs` is not the question "does this train" — the config that
  # announces three train epochs runs none.
  defp phases(setup) do
    "train #{yes_no(Setup.do_train(setup))} · eval #{yes_no(Setup.do_eval(setup))}"
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_off), do: "no"

  # Every object, in every epoch the config runs: "30 train · 140 eval". What
  # "Run it" promises before it is pressed.
  defp episodes_planned(setup) do
    objects = length(Setup.objects(setup))

    case Setup.epoch_plan(setup) do
      [] -> "none: the config switches both phases off"
      plan -> Enum.map_join(plan, " · ", fn {mode, epochs} -> "#{objects * epochs} #{mode}" end)
    end
  end

  # What the config's termination allows: the exploration allowance and the two
  # minimums from `/monty`, and the ceilings the `termination` group names. Each
  # is the experiment's, not a page's.
  defp budget(%{termination: termination, monty_args: args}) do
    [
      {"explore", Map.get(args, "num_exploratory_steps")},
      {"min eval", Map.get(args, "min_eval_steps")},
      {"min train", Map.get(args, "min_train_steps")},
      {"max eval", Map.get(termination, :max_eval_steps)},
      {"max train", Map.get(termination, :max_train_steps)},
      {"total", Map.get(termination, :max_total_steps)}
    ]
    |> Enum.reject(fn {_name, limit} -> is_nil(limit) end)
    |> Enum.map_join(" · ", fn {name, limit} -> "#{name} #{limit}" end)
    |> case do
      "" -> "not named by the config"
      named -> named
    end
  end
end
