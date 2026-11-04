defmodule Mix.Tasks.Monty.Run do
  @shortdoc "Runs a Monty experiment headlessly, step by step"

  @moduledoc """
  Runs one experiment without a browser, printing the same log the studio page
  streams.

      mix monty.run tutorial/first_experiment
      mix monty.run randrot_noise_10distinctobj_5lms_dist_agent --steps 40
      mix monty.run base_config_10distinctobj_dist_agent --no-record --quiet

  What runs is the experiment's own topology: every sensor and learning module
  is a supervised process, wired as its config wires them. A config that names a
  class this port has not written is refused rather than stood in for — a run of
  something else would wear the experiment's name — and the config is composed
  from Monty's own Hydra groups and checked before anything starts, so a config
  that would not start in Monty fails here too.

  A run is the whole experiment, as Monty's `evaluate` is: every object in every
  rotation the config names, each episode ending on its own recognition policy —
  not one episode out of a hundred and forty. A single episode is a smoke test
  that looks exactly like a result in the history, so it takes asking for:
  `--episodes N`. Either way the record keeps the number that actually ran, and
  so do the summary and the page.

  A run is recorded in the database by default, which is what makes a headless
  run appear in `/runs` next to one started from the page: same record, same
  log, same summary. `--no-record` is for throwaway runs and for benches.

  Exit status is 1 when the config would not start, so the task is usable from
  a script or a CI job.

  ## Options

    * `--steps N` — timesteps to run in an episode (default: #{12})
    * `--episodes N` — how many of the experiment's episodes to run (default:
      all of them: every object, in every rotation)
    * `--seed N` — episode seed, overriding the config's
    * `--pretrained-dir DIR` — the release to load pretrained models from, when
      the one the config names is not on this machine
    * `--record` / `--no-record` — whether to write a run history row
    * `--quiet` — findings and summary only, no per-step lines
  """

  use Mix.Task

  @requirements ["app.start"]

  @switches [
    steps: :integer,
    episodes: :integer,
    seed: :integer,
    record: :boolean,
    quiet: :boolean,
    pretrained_dir: :string
  ]

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

    history = record(opened, opts)
    {infos, history, conclusion} = run_phases(opened, opts, history)

    summary = summary(infos, opened.setup, conclusion)
    describe_run(finish(history, summary), summary)
  end

  # Monty's `run()`: every epoch of every phase the config runs, train before
  # eval, with the phase's mode told to the model. `--episodes` is the slice and
  # the only way to ask for less — a run that answered one episode out of a
  # hundred and forty answers a different question from the experiment.
  defp run_phases(opened, opts, history) do
    objects = length(Monty.Studio.Setup.objects(opened.setup))
    plan = Monty.Studio.Setup.epoch_plan(opened.setup)

    Enum.reduce(plan, {[], history, %{}}, fn {mode, epochs}, {infos, history, _conclusion} ->
      episodes = opts[:episodes] || objects * epochs
      scope = %{mode: mode, steps: steps(opened, opts), episodes: episodes}

      Enum.reduce(0..(episodes - 1)//1, {infos, history, %{}}, fn index,
                                                                  {infos, history, _conclusion} ->
        {episode_infos, history, conclusion} = run_episode(opened, scope, index, history, opts)
        {infos ++ episode_infos, history, conclusion}
      end)
    end)
  end

  # The safety cap an episode gets when the command names none: the config's own
  # ceiling on one episode. The per-mode limits belong to the recognition policy,
  # which is what actually ends an episode.
  defp steps(opened, opts) do
    opts[:steps] || Monty.Studio.Setup.max_total_steps(opened.setup) ||
      Monty.Studio.Run.default_steps()
  end

  # The episode index is also where the object comes from: the queued runner
  # starts its episodes the same way, so both cover the same ground.
  defp run_episode(opened, scope, index, history, opts) do
    {:ok, run} =
      Monty.Studio.Run.start(opened.setup, steps: scope.steps, episode: index, mode: scope.mode)

    :ok = Monty.Studio.Run.set_ground_truth(run)
    say_episode(index, scope.episodes, opts)

    beat = System.monotonic_time(:second)
    {infos, history, last_run} = step_through(run, history, opts, index, [], beat)
    conclusion = Monty.Studio.Run.conclusion(last_run)
    Monty.Studio.Run.stop(last_run)

    # The episode is what a run has to show for itself: the steps of an episode
    # are worth one write, and the record is the checkpoint, not the transcript.
    {Enum.reverse(infos), checkpoint(history), conclusion}
  end

  defp say_episode(_index, 1, _opts), do: :ok

  defp say_episode(index, count, opts) do
    unless opts[:quiet], do: Mix.shell().info("episode #{index + 1}/#{count}")
  end

  defp record(opened, opts) do
    if opts[:record] == false do
      nil
    else
      episodes = opts[:episodes] || Monty.Studio.Setup.planned_episodes(opened.setup)

      {:ok, history} =
        Monty.Studio.RunHistory.start(
          Monty.Studio.RunLog.attributes(opened, steps(opened, opts), 0, 1, episodes)
        )

      history
    end
  end

  defp step_through(run, history, opts, episode, infos, beat) do
    {:ok, info, observations, next_run} = Monty.Studio.Run.step(run)
    beliefs = Monty.Studio.Run.beliefs(run)
    print_step(info, beliefs, episode, opts)

    history = append(history, info, observations, beliefs, episode)
    beat = heartbeat(history, beat)
    infos = [info | infos]

    if Monty.Studio.Run.finished?(next_run) do
      {infos, history, next_run}
    else
      step_through(next_run, history, opts, episode, infos, beat)
    end
  end

  defp append(nil, _info, _observations, _beliefs, _episode), do: nil

  defp append(history, info, observations, beliefs, episode) do
    Monty.Studio.RunLog.append_step(history, info, observations, beliefs, episode: episode)
  end

  # An episode is minutes of stepping between two writes, and the Reaper judges a
  # run by its silence. A run being stepped says so, cheaply, rather than looking
  # abandoned for the length of an episode.
  @heartbeat_seconds 10

  defp heartbeat(nil, beat), do: beat

  defp heartbeat(history, beat) do
    now = System.monotonic_time(:second)

    if now - beat >= @heartbeat_seconds do
      Monty.Studio.RunHistory.alive(history)
      now
    else
      beat
    end
  end

  defp checkpoint(nil), do: nil

  defp checkpoint(history) do
    {:ok, saved} = Monty.Studio.RunHistory.checkpoint(history)
    saved
  end

  defp print_step(info, beliefs, episode, opts) do
    unless opts[:quiet] do
      entry = Monty.Studio.RunLog.entry(info, beliefs, episode: episode)
      Mix.shell().info(Monty.Studio.RunLog.line(entry))
    end
  end

  defp open(name, opts) do
    case Monty.Studio.open(name, pretrained_dir: opts[:pretrained_dir]) do
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

  defp summary(infos, setup, conclusion),
    do: Monty.Studio.Summary.from_infos(infos, setup, conclusion)

  defp finish(nil, _summary), do: nil

  defp finish(history, summary) do
    {:ok, history} =
      history
      |> checkpoint()
      |> Monty.Studio.RunHistory.finish(Monty.Studio.RunLog.summary(summary))

    history
  end

  defp report_experiment(name, opened) do
    setup = opened.setup

    Mix.shell().info(
      "#{name} (#{opened.source}) — #{class(setup.experiment_class)} on #{class(setup.monty_class)}"
    )

    # The list the studio's page shows before it runs the same config, read from
    # the same function: a terminal and a page that phrase the run separately are
    # two promises, and only one of them can be kept.
    for {label, value} <- Monty.Studio.Panel.facts(setup) do
      Mix.shell().info("  #{label}: #{value}")
    end

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

    # What the learning modules concluded, which is the question the experiment
    # asked. A module that never answered is timed out rather than left blank.
    Enum.each(summary.outcome, fn {id, conclusion} ->
      Mix.shell().info("  #{id}: #{conclusion || "no conclusion"}")
    end)

    case history do
      nil -> Mix.shell().info("  not recorded (--no-record)")
      history -> Mix.shell().info("  recorded as run #{history.id}")
    end
  end

  # The findings are the reason, and they have just been printed, so the closing
  # sentence must not claim one of its own: a config naming a class this port has
  # not written starts in Monty and does not start here.
  @spec refuse([Monty.Studio.Finding.t()]) :: no_return()
  defp refuse(findings) do
    findings
    |> Enum.reject(&(&1.level == :info))
    |> Enum.each(&Mix.shell().error(Monty.Studio.Finding.describe(&1)))

    Mix.raise("this run would not start: the findings above say why")
  end

  defp class(nil), do: "unknown"
  defp class(%{class: nil}), do: "unknown"
  defp class(%{class: class}), do: class
end
