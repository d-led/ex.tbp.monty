defmodule Mix.Tasks.Monty.Run do
  @shortdoc "Runs a Monty experiment headlessly, step by step"

  @moduledoc """
  Runs one experiment without a browser, printing the same log the studio page
  streams.

      mix monty.run tutorial/first_experiment
      mix monty.run randrot_noise_10distinctobj_5lms_dist_agent --steps 40
      mix monty.run base_config_10distinctobj_dist_agent --no-record --quiet

  What runs is the experiment's own topology: every sensor and learning module
  is a supervised process, wired as its config wires them, with synthetic
  stand-ins for the modules this port has not written yet. The config is
  composed from Monty's own Hydra groups and checked before anything starts, so
  a config that would not start in Monty fails here too.

  A run is recorded in the database by default, which is what makes a headless
  run appear in `/runs` next to one started from the page: same record, same
  log, same summary. `--no-record` is for throwaway runs and for benches.

  Exit status is 1 when the config would not start, so the task is usable from
  a script or a CI job.

  ## Options

    * `--steps N` — timesteps to run (default: #{12})
    * `--seed N` — episode seed, overriding the config's
    * `--record` / `--no-record` — whether to write a run history row
    * `--quiet` — findings and summary only, no per-step lines
  """

  use Mix.Task

  @requirements ["app.start"]

  @default_steps 12

  @switches [steps: :integer, seed: :integer, record: :boolean, quiet: :boolean]

  @impl true
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches)

    case argv do
      [experiment] -> run_experiment(experiment, opts)
      [] -> Mix.raise("which experiment? mix monty.run <experiment> [--steps N]")
      too_many -> Mix.raise("one experiment at a time, got: #{Enum.join(too_many, ", ")}")
    end
  end

  defp run_experiment(name, opts) do
    opened = open(name, opts)
    report_experiment(name, opened)

    unless Monty.Studio.Setup.valid?(opened.setup), do: refuse(opened.setup.findings)

    run = start(opened, opts)
    history = record(opened, run, opts)
    {infos, history, last_run} = step_through(run, history, opts, [])

    summary = summary(infos, opened.setup)
    describe_run(finish(history, summary), summary)
    # Leave nothing running: a headless process should end when the run does.
    Monty.Studio.Run.stop(last_run)
  end

  defp open(name, opts) do
    case Monty.Studio.open(name) do
      {:ok, opened} -> with_seed(opened, opts)
      {:error, reason} -> Mix.raise("could not open #{name}: #{inspect(reason)}")
    end
  end

  # The seed is the input a headless run most often varies: a sweep over seeds
  # is the simplest experiment there is.
  defp with_seed(opened, opts) do
    case opts[:seed] do
      nil -> opened
      seed -> %{opened | setup: %{opened.setup | seed: seed}}
    end
  end

  defp start(opened, opts) do
    {:ok, run} = Monty.Studio.Run.start(opened.setup, steps: opts[:steps] || @default_steps)
    run
  end

  defp record(opened, run, opts) do
    if opts[:record] == false do
      nil
    else
      {:ok, history} =
        Monty.Studio.RunHistory.start(Monty.Studio.RunLog.attributes(opened, run.steps))

      history
    end
  end

  defp step_through(run, history, opts, infos) do
    {:ok, info, observations, next_run} = Monty.Studio.Run.step(run)
    print_step(info, opts)
    history = if history, do: Monty.Studio.RunLog.record_step(history, info, observations)
    infos = [info | infos]

    if Monty.Studio.Run.finished?(next_run) do
      {Enum.reverse(infos), history, next_run}
    else
      step_through(next_run, history, opts, infos)
    end
  end

  defp print_step(info, opts) do
    unless opts[:quiet] do
      Mix.shell().info(Monty.Studio.RunLog.line(Monty.Studio.RunLog.entry(info)))
    end
  end

  defp summary(infos, setup), do: Monty.Studio.Summary.from_infos(infos, setup)

  defp finish(nil, _summary), do: nil

  defp finish(history, summary) do
    {:ok, history} = Monty.Studio.RunHistory.finish(history, Monty.Studio.RunLog.summary(summary))
    history
  end

  defp report_experiment(name, opened) do
    setup = opened.setup

    Mix.shell().info(
      "#{name} (#{opened.source}) — #{class(setup.experiment_class)} on #{class(setup.monty_class)}"
    )

    Mix.shell().info(
      "  sensors: #{Enum.map_join(setup.sensors, ", ", & &1.id)} → " <>
        "learning modules: #{Enum.map_join(setup.learning_modules, ", ", & &1.id)}"
    )

    Mix.shell().info(
      "  epochs: train #{setup.epochs.train} · eval #{setup.epochs.eval} · seed #{setup.seed}"
    )

    for finding <- setup.findings, finding.level != :info do
      Mix.shell().info("  " <> Monty.Studio.Finding.describe(finding))
    end
  end

  defp describe_run(history, summary) do
    Mix.shell().info(
      "#{summary.steps} steps in #{summary.duration_us} µs · " <>
        "votes #{summary.votes_used}/#{summary.votes_sent} · goals #{summary.goals} · " <>
        "deadline hits #{summary.deadline_hits}"
    )

    case summary.never_updated do
      [] -> :ok
      silent -> Mix.shell().info("  never received input: #{Enum.join(silent, ", ")}")
    end

    case history do
      nil -> Mix.shell().info("  not recorded (--no-record)")
      history -> Mix.shell().info("  recorded as run #{history.id}")
    end
  end

  @spec refuse([Monty.Studio.Finding.t()]) :: no_return()
  defp refuse(findings) do
    findings
    |> Enum.reject(&(&1.level == :info))
    |> Enum.each(&Mix.shell().error(Monty.Studio.Finding.describe(&1)))

    Mix.raise("this config would not start in Monty either")
  end

  defp class(nil), do: "unknown"
  defp class(%{class: nil}), do: "unknown"
  defp class(%{class: class}), do: class
end
