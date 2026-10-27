defmodule Mix.Tasks.Monty.Bench do
  @shortdoc "Times this port's timestep loop on real experiment shapes"

  @moduledoc """
  Runs experiments for a fixed number of timesteps and reports how fast the
  timestep loop is.

      mix monty.bench tutorial/first_experiment
      mix monty.bench randrot_noise_10distinctobj_5lms_dist_agent --steps 50 --repeat 5

  What this measures is **this port's runtime**: supervision, the sensor and
  learning-module barriers, the vote round with its deadline, the coordinator
  and the reporting. It is not an accuracy benchmark — Monty's own benchmarks
  (`benchmarks/*.csv`, the experiments they name) measure recognition, and they
  only become comparable once the model modules are ported. What this gives
  today is the number a profile needs: which experiment shape is slow.

  Nothing is recorded in the database, because a benchmark is not a run you want
  in `/runs`.

  ## Options

    * `--steps N` — timesteps per repetition (default: #{20})
    * `--repeat N` — repetitions, numbers reported as the median (default: #{3})
    * `--json` — machine-readable output, for a CI trend

  ## Profiling

  Once an experiment shape here is known to be slow, the next step is a profile,
  not a guess:

      mix run -e 'Mix.Tasks.Monty.Bench.run(["tutorial/first_experiment", "--steps", "200"])'
      :tprof.profile(fn -> Mix.Tasks.Monty.Bench.run(["tutorial/first_experiment", "--steps", "200"]) end)

  `:tprof` for where the time goes overall, `:eprof` for call counts, and
  `:fprof` when the order of calls matters.
  """

  use Mix.Task

  @requirements ["app.start"]

  @default_steps 20
  @default_repeat 3

  @switches [steps: :integer, repeat: :integer, json: :boolean]

  @type measurement :: %{
          experiment: String.t(),
          steps: non_neg_integer(),
          total_us: non_neg_integer(),
          mean_us: float(),
          p50_us: non_neg_integer(),
          p95_us: non_neg_integer(),
          max_us: non_neg_integer(),
          deadline_hits: non_neg_integer(),
          runnable?: boolean()
        }

  @impl true
  def run(args) do
    {opts, experiments} = OptionParser.parse!(args, strict: @switches)

    case experiments do
      [] -> Mix.raise("which experiment? mix monty.bench <experiment> [<experiment> ...]")
      experiments -> measure_all(experiments, opts)
    end
  end

  defp measure_all(experiments, opts) do
    results = Enum.map(experiments, &measure(&1, opts))

    if opts[:json] do
      Mix.shell().info(Jason.encode!(results, pretty: true))
    else
      table(results)
    end

    if Enum.any?(results, &(&1.runnable? == false)) do
      Mix.raise("some experiments would not start; fix their configs before benchmarking")
    end
  end

  defp measure(experiment, opts) do
    steps = opts[:steps] || @default_steps
    repeat = opts[:repeat] || @default_repeat

    case Monty.Studio.open(experiment) do
      {:ok, opened} ->
        if Monty.Studio.Setup.valid?(opened.setup) do
          samples = for _ <- 1..repeat, do: sample(opened, steps)
          summarise(experiment, samples, steps)
        else
          not_runnable(experiment, steps)
        end

      {:error, _reason} ->
        not_runnable(experiment, steps)
    end
  end

  defp sample(opened, steps) do
    {:ok, run} = Monty.Studio.Run.start(opened.setup, steps: steps)
    {infos, last_run} = step_through(run, [])

    # Every repetition is stopped as soon as it ends: a benchmark that leaves
    # processes behind measures the last run's load on the next one.
    Monty.Studio.Run.stop(last_run)

    %{
      durations: Enum.map(infos, & &1.duration_us),
      summary: Monty.Studio.Summary.from_infos(infos, opened.setup)
    }
  end

  defp step_through(run, infos) do
    {:ok, info, _observations, next_run} = Monty.Studio.Run.step(run)
    infos = [info | infos]

    if Monty.Studio.Run.finished?(next_run),
      do: {Enum.reverse(infos), next_run},
      else: step_through(next_run, infos)
  end

  # The median of the repetitions, because one unlucky run says more about the
  # machine than about the code.
  defp summarise(experiment, samples, steps) do
    durations = samples |> Enum.map(& &1.durations) |> List.flatten() |> Enum.sort()

    %{
      experiment: experiment,
      steps: steps,
      total_us: samples |> Enum.map(& &1.summary.duration_us) |> Enum.sort() |> median(),
      mean_us: durations |> Enum.sum() |> Kernel./(max(length(durations), 1)),
      p50_us: percentile(durations, 0.50),
      p95_us: percentile(durations, 0.95),
      max_us: List.last(durations) || 0,
      deadline_hits: samples |> Enum.map(& &1.summary.deadline_hits) |> Enum.max(),
      runnable?: true
    }
  end

  defp not_runnable(experiment, steps) do
    %{
      experiment: experiment,
      steps: steps,
      total_us: 0,
      mean_us: 0.0,
      p50_us: 0,
      p95_us: 0,
      max_us: 0,
      deadline_hits: 0,
      runnable?: false
    }
  end

  defp median([]), do: 0
  defp median(sorted), do: Enum.at(sorted, div(length(sorted), 2))

  defp percentile([], _fraction), do: 0

  defp percentile(sorted, fraction) do
    index = round(fraction * (length(sorted) - 1))
    Enum.at(sorted, index)
  end

  defp table(results) do
    Mix.shell().info(
      "experiment                                   steps  total µs  µs/step  p50  p95  max  deadlines"
    )

    Enum.each(results, fn result ->
      Mix.shell().info(
        String.pad_trailing(result.experiment, 44) <>
          String.pad_leading(Integer.to_string(result.steps), 6) <>
          String.pad_leading(Integer.to_string(result.total_us), 10) <>
          String.pad_leading(:erlang.float_to_binary(result.mean_us, decimals: 1), 9) <>
          String.pad_leading(Integer.to_string(result.p50_us), 5) <>
          String.pad_leading(Integer.to_string(result.p95_us), 5) <>
          String.pad_leading(Integer.to_string(result.max_us), 5) <>
          String.pad_leading(Integer.to_string(result.deadline_hits), 11)
      )
    end)
  end
end
