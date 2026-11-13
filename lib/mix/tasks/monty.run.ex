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
    * `--world mujoco|synthetic|cad` — which world to step. `cad` steps the
      STEP file `MONTY_CAD_PART` names, through `ex_monty_cad` (which the node
      has to carry). The default is this
      host's, and the stand-in scene is not the experiment: a number it reports
      is not the experiment's, so a run that should be comparable has to say
      `--world mujoco`
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
    pretrained_dir: :string,
    world: :string
  ]

  @impl true
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches)

    # This task steps an experiment in its own process; the studio's queue is
    # the server's. A node that takes a studio job publishes its steps into its
    # own memory, where no page can hear them — the page shows a run that is
    # stepping and never sees a step. So a CLI node steps nothing on the queue.
    Oban.pause_queue(queue: :studio)

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
    {infos, history, conclusion, outcomes} = run_phases(opened, opts, history)

    summary = summary(infos, opened.setup, conclusion, outcomes)

    unless opts[:quiet], do: Mix.shell().info(Monty.Studio.Summary.outcomes_line(outcomes))

    describe_run(finish(history, summary), summary)
  end

  # Monty's `run()`: every epoch of every phase the config runs, train before
  # eval, with the phase's mode told to the model. `--episodes` is the slice and
  # the only way to ask for less — a run that answered one episode out of a
  # hundred and forty answers a different question from the experiment.
  defp run_phases(opened, opts, history) do
    carried = %{
      memories: Monty.Studio.Setup.memories(opened.setup),
      first_seen: %{}
    }

    {infos, history, conclusion, carried, outcomes} =
      opened.setup
      |> Monty.Studio.Setup.epoch_plan()
      |> Enum.reduce({[], history, %{}, carried, %{}}, fn {mode, epochs}, acc ->
        run_phase(opened, mode, epochs, acc, opts)
      end)

    # What a training phase learned is written down here, through the same seam
    # the queue's worker uses: a run that trains keeps its memory whichever door
    # it was started by, and a run with no record keeps nothing.
    keep_memory(opened, history, carried.memories, opts)

    {infos, history, conclusion, outcomes}
  end

  defp keep_memory(opened, history, memories, opts) do
    plan = Monty.Studio.Setup.epoch_plan(opened.setup)
    run_id = history && history.id

    run_id
    |> Monty.Studio.Learned.keep(opened, plan, memories)
    |> Enum.each(fn line -> unless opts[:quiet], do: Mix.shell().info(line) end)
  end

  # One phase: a full one is every object it names in every epoch it names, and
  # an epoch walks *its* phase's objects — a config can train on two and
  # evaluate on one, which is two episodes a training epoch and one an
  # evaluation epoch.
  defp run_phase(
         opened,
         mode,
         epochs,
         {infos, history, _conclusion, carried, outcomes},
         opts
       ) do
    objects = length(Monty.Studio.Setup.objects(opened.setup, mode))
    episodes = opts[:episodes] || objects * epochs
    scope = %{mode: mode, steps: steps(opened, opts), episodes: episodes}

    Enum.reduce(
      0..(episodes - 1)//1,
      {infos, history, %{}, carried, outcomes},
      fn index, {infos, history, _conclusion, carried, outcomes} ->
        {episode_infos, history, conclusion, carried, outcomes} =
          run_episode(opened, scope, index, objects, history, carried, outcomes, opts)

        {infos ++ episode_infos, history, conclusion, carried, outcomes}
      end
    )
  end

  # The safety cap an episode gets when the command names none: the config's own
  # ceiling on one episode. The per-mode limits belong to the recognition policy,
  # which is what actually ends an episode.
  defp steps(opened, opts) do
    opts[:steps] || Monty.Studio.Setup.max_total_steps(opened.setup) ||
      Monty.Studio.Run.default_steps()
  end

  # The episode index is also where the object comes from: the queued runner
  # starts its episodes the same way, so both cover the same ground. The world an
  # episode shows, the object in it and the memory it matches against all come
  # from its own phase — `Setup.with_phase/2` and what the phase before it left
  # behind.
  #
  # An episode begins and ends through the *config's* experiment class, exactly
  # as the queued runner does it: a class is not a label on a page, and a
  # pretraining config that ran here without its class would explore and learn
  # nothing.
  defp run_episode(opened, scope, index, objects, history, carried, outcomes, opts) do
    # An epoch walks the phase's objects once, so the flat episode index of the
    # phase is two numbers Monty keeps apart: the epoch, and the episode within
    # it. Both are read — the sampler turns the object once per epoch, and the
    # episode's draws come from a seed derived from the episode within the epoch.
    {epoch, episode} = epoch_and_episode(index, objects)
    experiment = Monty.Studio.Setup.experiment_class(opened.setup)

    {:ok, run} =
      Monty.Studio.Run.start(Monty.Studio.Setup.with_phase(opened.setup, scope.mode),
        steps: scope.steps,
        episode: episode,
        epoch: epoch,
        mode: scope.mode,
        memory: carried.memories,
        first_seen: carried.first_seen
      )

    # The run is already started, so the class's `pre_episode` has nothing to
    # start: it adds what this experiment's episodes begin with, which is the
    # ground truth (and, for a supervised one, the switch to exploring).
    {:ok, state} = experiment.pre_episode(%{run: run}, index, object_of(run), episode_callbacks())

    say_episode(index, scope.episodes, opts)

    beat = nil
    {infos, history, last_run} = step_through(state.run, history, opts, index, [], beat)

    # The class states the episode's answer before it is written, and writing it
    # is what `next_memories/3` does.
    state =
      experiment.post_episode(%{run: last_run}, :finished, infos, episode_callbacks())

    last_run = state.run
    conclusion = Monty.Studio.Run.conclusion(last_run)
    outcomes = Monty.Studio.Summary.tally(outcomes, conclusion)

    unless opts[:quiet], do: Mix.shell().info(say_outcome(conclusion))

    carried = %{
      memories: next_memories(last_run, carried.memories, scope.mode),
      first_seen: last_run.first_seen
    }

    # A training episode has nothing to recognise, so what it has to show for
    # itself is the memory it just built.
    if scope.mode == :train do
      unless opts[:quiet] do
        Mix.shell().info(Monty.Studio.Learned.growth_line(carried.memories))
      end
    end

    Monty.Studio.Run.stop(last_run)

    # The episode is what a run has to show for itself: the steps of an episode
    # are worth one write, and the record is the checkpoint, not the transcript.
    {Enum.reverse(infos), checkpoint(history), conclusion, carried, outcomes}
  end

  # What one episode concluded, in the modules' own words, under the line that
  # said which episode it was. A run of two hundred and sixty-six episodes
  # reported only the last one's conclusion at the end, so a number a reader could
  # compare with Monty's was nowhere on the screen.
  defp say_outcome(conclusion) do
    conclusion
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {module_id, state} -> "#{module_id}: #{state}" end)
  end

  # What an experiment class may ask of this task: it does not own the world, the
  # run or the record, so the two hooks it can use are the ground truth — which
  # is `Monty.Studio.Run`'s own — and nothing at either end.
  defp episode_callbacks do
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
      _no_target -> nil
    end
  end

  # Monty's `model.update_ltm()`: what a training episode learned is what the
  # next episode starts from. A memory is what an episode leaves behind rather
  # than part of it, so a module that cannot answer for one is said out loud and
  # the phase goes on from the memory it had.
  defp next_memories(run, carried, mode) do
    Monty.Studio.Run.next_memories(run, carried, mode)
  rescue
    error ->
      Mix.shell().error("the memory could not be read: #{Exception.message(error)}")
      carried
  end

  # `index` is the phase's own episode counter and `objects` is how long an
  # epoch is, so the epoch is the division and the episode the remainder. A
  # phase with no objects is one episode an epoch, which is what a config that
  # names none runs.
  defp epoch_and_episode(index, objects) when objects > 0,
    do: {div(index, objects), rem(index, objects)}

  defp epoch_and_episode(index, _no_objects), do: {index, 0}

  defp say_episode(_index, 1, _opts), do: :ok

  defp say_episode(index, count, opts) do
    unless opts[:quiet], do: Mix.shell().info("episode #{index + 1}/#{count}")
  end

  # The record this task writes, claimed the way a worker claims one: this task
  # steps the run in its own process, so there is no queue between asking and
  # working, and a row left saying `queued` would be the record disagreeing with
  # the run it is writing. The claim is also where a run's start is stamped
  # (`RunHistory.mark_running/1`), so the duration this task leaves is its work.
  defp record(opened, opts) do
    if opts[:record] == false do
      nil
    else
      episodes = opts[:episodes] || Monty.Studio.Setup.planned_episodes(opened.setup)

      {:ok, history} =
        Monty.Studio.RunHistory.start(
          Monty.Studio.RunLog.attributes(opened, steps(opened, opts), 0, 1, episodes)
        )

      {:ok, history} = Monty.Studio.RunHistory.mark_running(history)
      history
    end
  end

  defp step_through(run, history, opts, episode, infos, beat) do
    {:ok, info, observations, next_run} = Monty.Studio.Run.step(run)
    beliefs = Monty.Studio.Run.beliefs(run)
    print_step(info, beliefs, episode, opts)

    history = append(history, info, observations, beliefs, episode)
    beat = Monty.Studio.RunHistory.heartbeat(history, beat)
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

  defp checkpoint(nil), do: nil

  # The transcript of an episode is worth a write; its pictures are not, because
  # appending to the row's `timeline` rewrites every picture the run has taken so
  # far (`RunHistory.store/3`). `finish/2` writes them, once.
  defp checkpoint(history) do
    {:ok, saved} = Monty.Studio.RunHistory.checkpoint(history, timeline: :skip)
    saved
  end

  defp print_step(info, beliefs, episode, opts) do
    unless opts[:quiet] do
      entry = Monty.Studio.RunLog.entry(info, beliefs, episode: episode)
      Mix.shell().info(Monty.Studio.RunLog.line(entry))
    end
  end

  defp open(name, opts) do
    open_options =
      [pretrained_dir: opts[:pretrained_dir], world_simulator: world(opts[:world])]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Monty.Studio.open(name, open_options) do
      {:ok, opened} -> with_seed(opened, opts)
      {:error, reason} -> Mix.raise("could not open #{name}: #{inspect(reason)}")
    end
  end

  # Named here so a misspelling is a refusal rather than a quietly different
  # world: `--world mujoco` that fell back to the stand-in would report numbers
  # that look like the experiment's and are not.
  defp world(nil), do: nil
  defp world("mujoco"), do: :mujoco
  defp world("synthetic"), do: :synthetic
  defp world("cad"), do: :cad

  defp world(other),
    do: Mix.raise("unknown world #{inspect(other)}: mujoco, synthetic or cad")

  # The seed is the input a headless run most often varies: a sweep over seeds
  # is the simplest experiment there is.
  defp with_seed(opened, opts) do
    case opts[:seed] do
      nil -> opened
      seed -> %{opened | setup: %{opened.setup | seed: seed}}
    end
  end

  defp summary(infos, setup, conclusion, outcomes),
    do: Monty.Studio.Summary.from_infos(infos, setup, conclusion, outcomes: outcomes)

  defp finish(nil, _summary), do: nil

  defp finish(history, summary) do
    {:ok, stored} = Monty.Studio.RunHistory.store(history, history.log, history.timeline)

    {:ok, history} =
      Monty.Studio.RunHistory.finish(stored, Monty.Studio.RunLog.summary(summary))

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
      "#{summary.steps} steps: #{summary.duration_us} µs in the model, " <>
        "#{summary.world_us} µs in the world · " <>
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
