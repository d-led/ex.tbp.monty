defmodule Mix.Tasks.Monty.Run do
  @shortdoc "Runs a Monty experiment headlessly, step by step"

  @moduledoc """
  Runs one experiment without a browser, printing the same log the studio page
  streams.

      mix monty.run tutorial/first_experiment
      mix monty.run randrot_noise_10distinctobj_5lms_dist_agent --steps 40
      mix monty.run base_config_10distinctobj_dist_agent --no-record --quiet
      mix monty.run base_config_10distinctobj_dist_agent --episodes 8 --parallel 4

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
  log, same summary, and the same statistics in the run's own folder — the
  handlers the config names are built and handed each episode before its memory is
  written, so a headless run's judgement is read from its `eval_stats.csv` exactly
  as a page-started run's is. `--no-record` is for throwaway runs and for benches;
  with no record there is no folder to report into.
  a script or a CI job.

  ## Options

    * `--steps N` — timesteps to run in an episode (default: the experiment's
      own limit). It is a *cap*, and a cap below what the config asks for is
      what turns a training episode into a fragment: `graph_exp1000_*` explores
      for a thousand steps, and a run cut at five hundred cannot match the graph
      it is building, so every epoch adds a new object instead of extending one.
    * `--episodes N` — how many of the experiment's episodes to run (default:
      all of them: every object, in every rotation)
    * `--seed N` — episode seed, overriding the config's
    * `--pretrained-dir DIR` — the release to load pretrained models from, when
      the one the config names is not on this machine
    * `--overlay DIR` — a config tree read before Monty's own copy: the
      experiments of ours that `mix monty.inputs` must not touch live in one
      (`priv/monty_experiments/conf`)
    * `--world mujoco|ex_mujoco|synthetic|image|cad` — which world to step. An
      image config's captures are opened by `image`. Both
      `mujoco` and `ex_mujoco` are the experiment's MuJoCo scene: the first is
      driven through the Python this application carries, the second is compiled
      and stepped by `ex_mujoco`'s NIF. `cad` steps the
      STEP file `MONTY_CAD_PART` names, through `ex_monty_cad` (which the node
      has to carry). The default is this
      host's, and the stand-in scene is not the experiment: a number it reports
      is not the experiment's, so a run that should be comparable has to say
      `--world mujoco`
    * `--record` / `--no-record` — whether to write a run history row
    * `--parallel N` — divide the experiment into `N` parts and let the queue's
      own runner perform them at once, which is Monty's `run_parallel.py` as a
      division of episodes (`Monty.Studio.Partition`). The parts are the run's
      record, so `--parallel` needs a recorded run and refuses `--no-record`
      rather than running undivided under a name that promised otherwise.
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
    overlay: :string,
    world: :string,
    sensors: :string,
    scheduling: :string,
    settle: :integer,
    parallel: :integer
  ]

  @impl true
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches)

    # This task steps an experiment in its own process; the studio's queue is
    # the server's. A node that takes a studio job publishes its steps into its
    # own memory, where no page can hear them — the page shows a run that is
    # stepping and never sees a step. So a CLI node steps nothing on the queue.
    Oban.pause_queue(queue: :studio)

    # The ceilings a studio run carries apply here too: a CLI experiment is the
    # same model with the same modules, and the heap limit is the runtime's own
    # default for every process started from now on (`Monty.Studio.RunLimits`).
    :ok = Monty.Studio.RunLimits.apply_heap_limit()

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

    if divided?(opts), do: run_divided(opened, opts), else: run_whole(opened, opts)
  end

  defp divided?(opts), do: is_integer(opts[:parallel]) and opts[:parallel] > 1

  # One run, one process, episode after episode: the shape this task has always
  # had, and what `--parallel 1` asks for.
  defp run_whole(opened, opts) do
    history = record(opened, opts)

    # The statistics the config asks for, built exactly as the queue's worker
    # builds them (`Monty.Studio.Logging`): a headless run is history like any
    # other, and a run that kept its steps and lost its numbers would be a second
    # kind of run wearing the same name.
    logging = Monty.Studio.Logging.open(opened.setup)
    {infos, history, conclusion, outcomes} = run_phases(opened, opts, history, logging)

    summary = summary(infos, opened.setup, conclusion, outcomes)

    unless opts[:quiet], do: Mix.shell().info(Monty.Studio.Summary.outcomes_line(outcomes))

    describe_run(finish(history, summary), summary)
  end

  # Monty's `run_parallel.py` from the command line: the experiment divided into
  # parts, and each part performed by the queue's own runner — the division the
  # page offers, reused rather than restated, so there is one answer to "which
  # episodes does a part take" and one worker that takes them.
  #
  # A part is a piece of a run's record, so a divided run is recorded. The
  # refusal is a sentence rather than a quiet fallback to an undivided run,
  # which would print a divided run's name over work that was never divided.
  defp run_divided(opened, opts) do
    count = opts[:parallel]

    if opts[:record] == false do
      Mix.raise(
        "--parallel #{count} needs a record: a part lives in a run's record, " <>
          "and `--no-record` leaves none"
      )
    end

    parts =
      opened.setup
      |> Monty.Studio.Partition.plan(count, opts[:episodes])
      |> Monty.Studio.Partition.parts()
      |> Enum.map(&Map.put(&1, :stream, Ecto.UUID.generate()))

    {:ok, record} =
      Monty.Studio.RunHistory.start(
        Monty.Studio.RunLog.attributes(
          opened,
          steps(opened, opts),
          0,
          count,
          opts[:episodes],
          Map.put(levers(opts), :parts, parts)
        )
      )

    summary =
      case Monty.Studio.Jobs.Run.perform(%Oban.Job{args: %{"run_id" => record.id}, attempt: 1}) do
        {:ok, closed} -> Monty.Studio.Summary.restore(closed.summary)
        {:error, reason} -> Mix.raise("the divided run did not finish: #{inspect(reason)}")
      end

    unless opts[:quiet],
      do: Mix.shell().info(Monty.Studio.Summary.outcomes_line(summary.outcomes))

    describe_run(Monty.Studio.RunHistory.get(record.id), summary)
  end

  # Monty's `run()`: every epoch of every phase the config runs, train before
  # eval, with the phase's mode told to the model. `--episodes` is the slice and
  # the only way to ask for less — a run that answered one episode out of a
  # hundred and forty answers a different question from the experiment.
  defp run_phases(opened, opts, history, logging) do
    # A phase starts with nothing in hand and reads its library where it steps:
    # each module builds its own memory from the library its config names, in the
    # module's own process (`Setup.model_spec/3`'s `lazy_state`). Loading it here
    # instead put a two-hundred-megabyte term in this process and in every copy of
    # the spec the model and its modules are handed, which is what a 77-object run
    # died of.
    carried = %{
      memories: %{},
      first_seen: %{},
      # What each graph was built from. A training episode adds to it — the phase
      # learns one object per episode, each under a graph id of its own — and an
      # evaluation episode leaves it alone.
      targets: %{}
    }

    {infos, history, conclusion, carried, outcomes, _logging} =
      opened.setup
      |> Monty.Studio.Setup.epoch_plan()
      |> Enum.reduce({[], history, %{}, carried, %{}, logging}, fn {mode, epochs}, acc ->
        run_phase(opened, mode, epochs, acc, opts)
      end)

    # What a training phase learned is written down here, through the same seam
    # the queue's worker uses: a run that trains keeps its memory whichever door
    # it was started by, and a run with no record keeps nothing.
    keep_memory(opened, history, carried, opts)

    {infos, history, conclusion, outcomes}
  end

  defp keep_memory(opened, history, carried, opts) do
    plan = Monty.Studio.Setup.epoch_plan(opened.setup)
    run_id = history && history.id

    run_id
    |> Monty.Studio.Learned.keep(opened, plan, carried.memories, targets: carried.targets)
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
         {infos, history, _conclusion, carried, outcomes, logging},
         opts
       ) do
    objects = length(Monty.Studio.Setup.objects(opened.setup, mode))
    episodes = opts[:episodes] || objects * epochs
    scope = %{mode: mode, steps: steps(opened, opts), episodes: episodes}

    # What travels from one episode to the next: the record, the memory the
    # phase has built, the tallies, and the plan this run reports its
    # statistics through. One state rather than four arguments, which is also
    # the shape the queue's worker keeps.
    state = %{
      history: history,
      conclusion: %{},
      carried: carried,
      outcomes: outcomes,
      logging: logging
    }

    {infos, state} =
      Enum.reduce(0..(episodes - 1)//1, {infos, state}, fn index, {infos, state} ->
        {episode_infos, state} = run_episode(opened, scope, index, objects, state, opts)

        {infos ++ episode_infos, state}
      end)

    {infos, state.history, state.conclusion, state.carried, state.outcomes, state.logging}
  end

  # The safety cap an episode gets when the command names none: the config's own
  # ceiling on one episode. The per-mode limits belong to the recognition policy,
  # which is what actually ends an episode.
  defp steps(opened, opts) do
    opts[:steps] || Monty.Studio.Run.cap(opened.setup)
  end

  # What an episode starts from: the memory the last training episode wrote, and
  # what its graphs were built from. Empty at a phase's first episode, and then
  # left out rather than handed over empty — a run with no memory in hand reads
  # the library its config names, and a module reads it in its own process.
  defp knowledge(%{memories: memories}) when memories == %{}, do: []

  defp knowledge(%{memories: memories, targets: targets}),
    do: [memory: memories, memory_targets: targets]

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
  defp run_episode(opened, scope, index, objects, run_state, opts) do
    %{carried: carried, history: history, logging: logging, outcomes: outcomes} = run_state
    # An epoch walks the phase's objects once, so the flat episode index of the
    # phase is two numbers Monty keeps apart: the epoch, and the episode within
    # it. Both are read — the sampler turns the object once per epoch, and the
    # episode's draws come from a seed derived from the episode within the epoch.
    {epoch, episode} = epoch_and_episode(index, objects)
    experiment = Monty.Studio.Setup.experiment_class(opened.setup)

    {:ok, run} =
      Monty.Studio.Run.start(
        Monty.Studio.Setup.with_phase(opened.setup, scope.mode),
        [
          steps: scope.steps,
          episode: episode,
          epoch: epoch,
          mode: scope.mode,
          first_seen: carried.first_seen,
          has_detailed_logger: Monty.Studio.Logging.detailed?(logging)
        ] ++ knowledge(carried) ++ run_levers(opts)
      )

    # The run is already started, so the class's `pre_episode` has nothing to
    # start: it adds what this experiment's episodes begin with, which is the
    # ground truth (and, for a supervised one, the switch to exploring).
    {:ok, state} = experiment.pre_episode(%{run: run}, index, object_of(run), episode_callbacks())

    say_episode(index, scope.episodes, opts)

    beat = nil
    {infos, history, last_run} = step_through(state.run, history, opts, index, [], beat)

    # The episode's statistics, before the episode's memory is written: Monty's
    # order, and the same call the queue's worker makes
    # (`Monty.Studio.Jobs.Run`). A training episode's ground truth is rewritten
    # on the way into the memory, so an episode logged afterwards would look
    # confused about the object it just recognised.
    logging = report(logging, last_run, history, opts)

    # The class states the episode's answer before it is written, and writing it
    # is what `next_memories/3` does.
    state =
      experiment.post_episode(%{run: last_run}, :finished, infos, episode_callbacks())

    last_run = state.run
    conclusion = Monty.Studio.Run.conclusion(last_run)
    outcomes = Monty.Studio.Summary.tally(outcomes, conclusion)

    unless opts[:quiet], do: Mix.shell().info(say_outcome(conclusion))

    carried = learned_from(last_run, carried, scope)

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
    run_state = %{
      run_state
      | history: checkpoint(history),
        conclusion: conclusion,
        carried: carried,
        outcomes: outcomes,
        logging: logging
    }

    {Enum.reverse(infos), run_state}
  end

  # The episode's statistics, into the run's own folder, through the same plan a
  # page-started run reports through. `--no-record` is the one run with no folder
  # to report into, and the mode that promises to leave nothing behind.
  #
  # A report that fails leaves the run going: the episode is real and the file is
  # missing, which is said rather than raised — the same reading
  # `Monty.Studio.Jobs.Run` takes.
  defp report(logging, _run, nil, _opts), do: logging

  defp report(logging, run, history, opts) do
    case Monty.Studio.Logging.report(logging, run, Monty.Studio.Artifacts.dir(history.id)) do
      {:ok, reported} ->
        reported

      {:skipped, reported} ->
        reported

      {:error, reason} ->
        unless opts[:quiet],
          do: Mix.shell().info("the statistics could not be written: #{inspect(reason)}")

        logging
    end
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

  # What the next episode starts from: the memory this one built, where each
  # object stood, and what each of its graphs was built from.
  #
  # The order is this function's and not a map literal's: `next_memories/3` is
  # `update_ltm`, the only moment a training episode writes to memory, and the
  # graph-to-object map is written by that same call. Read in the other order it
  # is the map the episode *started* with — which named each graph after itself,
  # so the library said `new_object0 → new_object0` and an unsupervised memory
  # went on declaring itself unlabelled.
  defp learned_from(last_run, carried, scope) do
    memories = next_memories(last_run, carried.memories, scope.mode)

    %{
      memories: memories,
      first_seen: last_run.first_seen,
      targets: targets_after(last_run, carried.targets, scope.mode)
    }
  end

  # The names a phase has learned are every episode's, not the last one's: a
  # training episode builds a graph of its own and names it, so a phase of five
  # episodes has five answers, four of which replacing would throw away — and it
  # did, which is how a five-dog library was written with every graph called
  # `new_object0`. `Monty.Studio.Run.merge_targets/2` is this port's addition.
  defp targets_after(run, carried, :train),
    do: Monty.Studio.Run.merge_targets(carried, Monty.Studio.Run.memory_targets(run))

  defp targets_after(_run, carried, :eval), do: carried

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
          Monty.Studio.RunLog.attributes(
            opened,
            steps(opened, opts),
            0,
            1,
            episodes,
            levers(opts)
          )
        )

      {:ok, history} = Monty.Studio.RunHistory.mark_running(history)
      # The folder and the row pointing at it, the way a page-started run gets
      # them: a headless run is history like any other, log included.
      Monty.Studio.Jobs.Run.begin(history)
    end
  end

  # The three choices a run carries beside its size — how its steps are scheduled,
  # how many steps a module still computing gets after a conclusion, and whether a
  # step serves its sensors one after another or at once. The page offers them in
  # the budget row; the command line is where two runs of one seed are compared
  # without a browser, so it offers the same three and refuses a value it cannot
  # read rather than running the default under a name that says otherwise.
  defp levers(opts) do
    %{
      scheduling: scheduling_of(opts[:scheduling]),
      settle: opts[:settle] || 0,
      sensors: sensors_of(opts[:sensors])
    }
  end

  defp scheduling_of(nil), do: Monty.Studio.Jobs.scheduling()
  defp scheduling_of(setting) when setting in ["wait_for_all", "barrier"], do: :wait_for_all

  defp scheduling_of(setting) when setting in ["one_step_behind", "lagged"],
    do: :one_step_behind

  defp scheduling_of(other),
    do: Mix.raise("scheduling is `barrier` or `lagged`, got: #{inspect(other)}")

  defp sensors_of(nil), do: :auto
  defp sensors_of("auto"), do: :auto
  defp sensors_of("serial"), do: :serial
  defp sensors_of("concurrent"), do: :concurrent

  defp sensors_of(other),
    do: Mix.raise("sensors is `auto`, `serial` or `concurrent`, got: #{inspect(other)}")

  # What the levers become in a run's options: only the ones asked for, so a run
  # that named none is the run this task always started.
  defp run_levers(opts) do
    [
      opts[:settle] && {:settle_steps, opts[:settle]},
      opts[:scheduling] && {:scheduling, scheduling_of(opts[:scheduling])},
      opts[:sensors] && {:sensors_step, sensors_of(opts[:sensors])}
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp step_through(run, history, opts, episode, infos, beat) do
    case Monty.Studio.RunLimits.watch_step(fn -> Monty.Studio.Run.step(run) end) do
      {:ok, {:ok, info, observations, next_run}} ->
        beliefs = Monty.Studio.Run.beliefs(run)
        print_step(info, beliefs, episode, history, opts)

        history = append(history, info, observations, beliefs, episode)
        beat = Monty.Studio.RunHistory.heartbeat(history, beat)
        infos = [info | infos]

        if Monty.Studio.Run.finished?(next_run) do
          {infos, history, next_run}
        else
          step_through(next_run, history, opts, episode, infos, beat)
        end

      # A step is a call to the process holding the model, and that process can
      # be killed by its heap ceiling. A killed process takes the call's exit with
      # it — no exception, nothing said — and an uncaught one ends the whole VM,
      # which is how a run's log came to stop at a step with no summary (§2.35).
      {:error, reason} ->
        Mix.raise(
          "the run stopped at a step: " <> Monty.Studio.RunLimits.stopped_sentence(reason)
        )
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
  #
  # A checkpoint that cannot be written is said out loud and the run goes on. An
  # episode of a training phase can take minutes, and a database connection is
  # not held that long: the ten-epoch sweep of the dog corpus died at its first
  # episode boundary because the record's row was no longer there to be written,
  # and a bookkeeping write is not worth nine epochs of stepping.
  defp checkpoint(history) do
    case Monty.Studio.RunHistory.checkpoint(history, timeline: :skip) do
      {:ok, saved} ->
        saved

      {:error, reason} ->
        Mix.shell().error(
          "the run's transcript could not be written at an episode boundary " <>
            "(#{inspect(reason)}); the episode is in the run's own log"
        )

        history
    end
  end

  # The line a page's stream writes into the run's log, printed here and appended
  # there: one sentence per step, the same one in both places. `--no-record` is
  # the mode with no folder, so it prints and writes nothing.
  defp print_step(info, beliefs, episode, history, opts) do
    entry = Monty.Studio.RunLog.entry(info, beliefs, episode: episode)
    line = Monty.Studio.RunLog.line(entry)
    unless opts[:quiet], do: Mix.shell().info(line)
    if history, do: Monty.Studio.Jobs.Run.log_line(history.id, line)
  end

  defp open(name, opts) do
    open_options =
      [
        pretrained_dir: opts[:pretrained_dir],
        world_simulator: world(opts[:world]),
        conf_dir: conf_dir(opts[:overlay])
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Monty.Studio.open(name, open_options) do
      {:ok, opened} -> with_seed(opened, opts)
      {:error, reason} -> Mix.raise("could not open #{name}: #{inspect(reason)}")
    end
  end

  # An overlay is the tree of configs that differ, read before the copy of
  # Monty's own: that is how an experiment of ours composes against the whole of
  # Monty's config without copying it (`ExTbpMonty.AnimalExperiments`).
  #
  # With no `--overlay` the roots are the discovered ones — every experiment set
  # this application carries, the group files they share, then Monty's mirror —
  # so an experiment that appears in a set runs by name with no flag, which is
  # what the catalog offers.
  defp conf_dir(nil), do: Monty.Config.Source.conf_dirs()

  defp conf_dir(overlay), do: [Path.expand(overlay) | Monty.Config.Source.conf_dirs()]

  # Named here so a misspelling is a refusal rather than a quietly different
  # world: `--world mujoco` that fell back to the stand-in would report numbers
  # that look like the experiment's and are not.
  defp world(nil), do: nil
  defp world("mujoco"), do: :mujoco
  defp world("ex_mujoco"), do: :ex_mujoco
  defp world("synthetic"), do: :synthetic
  defp world("cad"), do: :cad
  defp world("image"), do: :image
  defp world("omniglot"), do: :omniglot

  defp world(other),
    do: Mix.raise("unknown world #{inspect(other)}: mujoco, ex_mujoco, synthetic, image or cad")

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

  # The closing write is the record's, and a record whose connection went away is
  # what a long run has: an episode of a training phase outlives the database's
  # ownership timeout, and the run's own log has every step either way. So the
  # answer is read, said out loud when it failed, and the run ends with its
  # summary rather than with a `MatchError` in its last line.
  defp finish(history, summary) do
    with {:ok, stored} <- Monty.Studio.RunHistory.store(history, history.log, history.timeline),
         {:ok, finished} <-
           Monty.Studio.RunHistory.finish(stored, Monty.Studio.RunLog.summary(summary)) do
      finished
    else
      {:error, reason} ->
        Mix.shell().error(
          "the run's record could not be closed (#{inspect(reason)}); " <>
            "the run's own log holds what it did"
        )

        history
    end
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
