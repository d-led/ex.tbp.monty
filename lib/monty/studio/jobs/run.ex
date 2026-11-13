defmodule Monty.Studio.Jobs.Run do
  @moduledoc """
  One experiment run, as a queued job.

  A run used to live inside the page that started it, which meant closing the
  page killed the run and refreshing it lost the run's progress. A run is a job
  instead: the page enqueues it, the queue performs it, and the page watches by
  subscribing to `"studio:run:<id>"`. What the run did is in `studio_runs`; what
  it printed is in `priv/studio_runs/<id>/run.log`; both are written as it goes,
  so a run that dies leaves a record of how far it got.

  A step's own report is not written to the database as it is taken: it goes to
  `Monty.Studio.RunStream`, in memory, which is where the page watching the run
  reads it from — Monty's logger and its dashboard do the same. The row gets the
  transcript at every episode boundary and the pictures once, when the run
  settles, which keeps a step's cost a function of the step rather than of how
  long the run has been going.

  Stopping is a message, not a kill: the worker checks its mailbox between
  timesteps, so a stop lands at a step boundary and the summary describes the
  steps that actually happened.
  """

  use Oban.Worker, queue: :studio, max_attempts: 1

  require Logger

  alias ExTbpMonty.Cluster.{Nodes, Placement, Protocol}
  alias Monty.Studio

  alias Monty.Studio.{
    Artifacts,
    CentreView,
    Claim,
    Failure,
    Learned,
    Logging,
    Memories,
    Partition,
    Run,
    RunHistory,
    RunLog,
    RunStream,
    RunWriter,
    Setup,
    Summary
  }

  alias Monty.Studio.Jobs.Stops

  @doc "Enqueues a run of `attributes` (see `RunLog.attributes/2`) and returns the job."
  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(attributes) do
    case RunHistory.start(attributes) do
      {:ok, record} -> enqueue_run(record)
      {:error, changeset} -> {:error, {:cannot_record, changeset}}
    end
  end

  @doc "Enqueues a run of an experiment already recorded."
  @spec enqueue_run(RunHistory.Run.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_run(%RunHistory.Run{id: id}) do
    %{"run_id" => id}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Asks every worker of a run to stop at the next step boundary.

  `:not_found` means no worker holds that run — it finished, or it never
  started — which is nothing to panic about.

  A divided run's parts may be performed by peers, and a stop that reached only
  this node's processes would leave them stepping: the run would say `stopped`
  with work still running on a machine the page cannot see. So the stop is also
  cast to the node each part was given to (`stop_part/1`), before the local
  answer is decided.
  """
  @spec stop(binary()) :: :ok | {:error, :not_found}
  def stop(run_id) do
    # One read for both halves: the run's own plan says which parts exist and
    # which of them are stepping on another node.
    record = RunHistory.get(run_id)
    stop_parts_there(record)

    case workers(record, run_id) do
      [] ->
        {:error, :not_found}

      pids ->
        # The message reaches the worker, which owns the clock; the flag reaches
        # the tasks it started, which is where the steps actually happen.
        Stops.ask(run_id)
        Enum.each(pids, &send(&1, :stop))
        :ok
    end
  end

  @doc """
  Asks one part to stop, on the node performing it.

  The other half of `stop/1`, and public because it is called over `:rpc`: a part
  on a peer is a process in that peer's registry, under its stream id. A node that
  is not performing that part answers `:not_found`, which is why the stop is a
  cast — nobody waits for a peer to say it had nothing to stop.
  """
  @spec stop_part(binary()) :: :ok | {:error, :not_found}
  def stop_part(stream_id) do
    case Registry.lookup(Monty.Runtime.Registry, key(stream_id)) do
      [] ->
        {:error, :not_found}

      owners ->
        Enum.each(owners, fn {pid, _value} -> send(pid, :stop) end)
        :ok
    end
  end

  # The parts a peer is performing. Recomputed from the plan and the cluster
  # rather than read from the part rows: the rows name a node per part, and a run
  # that trains and then evaluates has two parts numbered nought. A cast to a node
  # this run never had is harmless (`stop_part/1` finds no process), and the
  # recomputation is the same answer `hosts_for/2` acted on.
  defp stop_parts_there(%{inputs: inputs} = record) do
    for {part, [host | _rest]} <-
          Partition.hosts(planned(record), Nodes.snapshot(), Placement.needs(inputs)),
        host.node != node() do
      :rpc.cast(host.node, __MODULE__, :stop_part, [part.stream])
    end

    :ok
  end

  defp stop_parts_there(_no_run), do: :ok

  # Everyone stepping the run, which is the job that holds it and each part it is
  # stepping. A part runs in a process of its own (`Task.async_stream/3`), so a
  # stop that reached only the job would wait in a mailbox the job cannot read
  # while it is waiting for its parts: the run would finish, not stop.
  #
  # A record that cannot be read is still an id a worker may have registered
  # under before its row existed, and the id is all the message needs.
  defp workers(record, run_id) do
    if(record, do: working_on(record), else: [run_id])
    |> Enum.flat_map(&Registry.lookup(Monty.Runtime.Registry, key(&1)))
    |> Enum.map(fn {pid, _value} -> pid end)
    |> Enum.uniq()
  end

  # The run and the streams its parts are stepping. A run of one part has no
  # division to read, and the record is asked rather than kept here because the
  # stop may be asked from a page, a tool, or a peer's rpc call.
  defp working_on(%{id: run_id, inputs: %{"parts" => [_ | _] = parts}}),
    do: [run_id | Enum.map(parts, & &1["stream"])]

  defp working_on(%{id: run_id}), do: [run_id]

  @doc """
  Ends the worker's process now, on this node.

  The version of `stop/1` for a step that will not finish: the worker is killed
  rather than asked, so the run cannot write its own summary. The model goes with
  it — a model is a supervised child of its own and would outlive the run — and so
  does the world, which the worker started and which therefore dies with the
  process that started it.

  `{:error, :not_found}` means no worker here holds that run. A caller that means
  to stop a run wherever it is asks this on the node the row names
  (`Monty.Studio.Jobs.halt/1`).
  """
  @spec halt(binary()) :: :ok | {:error, :not_found}
  def halt(run_id) do
    case owner(run_id) do
      [{pid, model_id}] ->
        Process.exit(pid, :kill)
        if is_binary(model_id), do: Monty.Runtime.Model.stop(model_id)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc "The topic a run's progress is broadcast on."
  @spec topic(binary()) :: String.t()
  def topic(run_id), do: "studio:run:" <> run_id

  @doc """
  The experiment a record describes: its config, the world it was started
  with, and the seed it kept.

  A record is what a run is told to be. Two of its fields are choices the
  config cannot make for a particular run — the world to step and the seed to
  step it from — so they are read back here rather than taken from the config a
  second time. A record that kept no seed leaves the config's own, which is
  what `Monty.Studio.Setup.with_seed/2` reads `nil` as.
  """
  @spec opened_for(RunHistory.Run.t()) :: {:ok, Studio.opened()} | {:error, term()}
  def opened_for(%RunHistory.Run{experiment: name, inputs: inputs, seed: seed}) do
    case Studio.open(name, world_simulator: world_of(inputs)) do
      {:ok, opened} -> runnable(%{opened | setup: Setup.with_seed(opened.setup, seed)})
      {:error, reason} -> {:error, reason}
    end
  end

  # The queue refuses what the page refuses. A config built from classes this
  # port has not written cannot run here, and a record marked `failed` with the
  # reason is a truer record than a run that stands a module in and reports
  # nothing about the experiment.
  defp runnable(opened) do
    case Setup.findings(opened.setup, :error) do
      [] -> {:ok, opened}
      [first | _rest] -> {:error, first.message}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    # Ownership first, before anything can fail. "Is a process working on this
    # run" is the question `Monty.Studio.Jobs.Reaper` asks, and a run that is
    # being attempted has an owner even while it is still opening its world.
    register(run_id)

    try do
      with {:ok, record} <- fetch(run_id),
           :here <- my_turn(record),
           {:ok, opened} <- opened_for(record) do
        # The record says `queued` until here, because asking for a run is not
        # running it: this is the moment a worker has it in hand.
        {:ok, record} = RunHistory.mark_running(record)
        run_experiment(record, opened)
      else
        # A peer offers what this run needs and this node does not: the job goes
        # back to the queue for that peer's worker to take. Nothing is opened,
        # nothing is recorded — the run is still `queued`, which is true.
        {:wait, seconds} -> {:snooze, seconds}
        {:error, reason} -> give_up(run_id, reason)
      end
    rescue
      exception ->
        died(run_id, Failure.crashed(:error, exception, __STACKTRACE__))
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        died(run_id, Failure.crashed(kind, reason, __STACKTRACE__))
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      unregister(run_id)
    end
  end

  # Whether this node may perform the run, which on a node that runs alone is
  # always yes: its list of nodes holds itself, it offers `monty`, and a run that
  # asked for something nobody offers is performed here rather than waiting for
  # a node that does not exist (`ExTbpMonty.Cluster.Placement`).
  defp my_turn(%{inputs: inputs}) do
    Placement.turn(Nodes.snapshot(), Placement.needs(inputs))
  end

  @doc """
  Whether a process on this node is working on `run_id` right now.

  This is the only evidence of a live run that cannot be stale: a record says
  "running" until somebody closes it, and an Oban job says `executing` until its
  node is gone and nothing notices. A registered worker is a process that exits
  when it stops working, and the registry forgets it then.
  """
  @spec held?(binary()) :: boolean()
  def held?(run_id), do: Registry.lookup(Monty.Runtime.Registry, key(run_id)) != []

  @doc """
  The process working on a run, and the model it is stepping — `[]` when nobody
  is.

  The model id is what a cancelled run's leftover processes are found by, so a
  caller that ends a run out of band (see `Monty.Studio.Jobs.halt/1`) needs it
  before the process that owns it is gone.
  """
  @spec owner(binary()) :: [{pid(), term()}]
  def owner(run_id), do: Registry.lookup(Monty.Runtime.Registry, key(run_id))

  # -- the run ---------------------------------------------------------------

  # One press of Run is one record and one job, whatever it was asked to do with
  # its work. A run asked for several parts runs them here, in this process's own
  # pool; there is still one row, one topic and one transcript.
  defp run_experiment(record, opened) do
    case parallel(record) do
      1 -> run_alone(record, opened)
      count -> run_partitioned(record, opened, count)
    end
  end

  # One run is one *epoch*: an episode per object the experiment names, each of
  # them ending the way Monty's does — the recognition policy said done, or the
  # page's step budget ran out. The loop is the experiment class's
  # (`MontyExperiment.run_epoch/2`); this function is the world, the records and
  # the page, which the loop asks for through callbacks.
  defp run_alone(record, opened) do
    run_id = record.id
    log_ready = Artifacts.start(run_id)
    # A part's log is its own stream's, and the row it would be attached to is the
    # run's, which the run has already attached: the part writes its lines to its
    # own file and leaves the row alone.
    record = if part?(record), do: record, else: attach_log(record, run_id, log_ready)
    sensor_ids = Setup.sensor_ids(opened.setup)
    experiment = Setup.experiment_class(opened.setup)
    # An epoch walks its own phase's objects: a config can train on two and
    # evaluate on one, which is two episodes a training epoch and one an
    # evaluation epoch.
    objects = %{
      train: Setup.objects(opened.setup, :train),
      eval: Setup.objects(opened.setup, :eval)
    }

    # How much of the experiment this run is: all of it, unless its record says
    # fewer episodes or names the ones a part of a parallel batch takes
    # (`Monty.Studio.Partition`). The number is per phase, so a two-phase config
    # sliced to two runs two of each; every shipped config has one phase, where
    # the two are the same.
    episodes = episodes_of(record, Setup.planned_episodes(opened.setup))

    # What this run will leave behind is the config's answer, not the page's: the
    # handlers it names are also what decides whether the modules keep the whole
    # hypothesis space, which is Monty's `init_monty_data_loggers`.
    logging = Logging.open(opened.setup)
    plan = phases_of(record, opened.setup)

    say(
      run_id,
      "run started: #{record.experiment}, #{objects_line(objects)} × " <>
        "#{phases_line(plan)}, #{episodes} episode(s) in all, " <>
        "up to #{record.steps} steps each"
    )

    broadcast(run_id, {:started, record.steps})

    # A class the config names that this port does not have is said out loud
    # once, at the start, and the run goes on without it.
    Enum.each(
      logging.notes ++ Logging.describe(logging, Artifacts.dir(run_id)),
      &say(run_id, &1)
    )

    # `episode` is the episode of the run the steps now belong to: the step
    # counter restarts inside each one, and what a record and a page keep of a
    # step has to say which episode it was in (`RunLog.entry/3`). `mode` is the
    # phase being run — Monty sets it on the model before the epoch steps, and
    # it is what his ending rule reads.
    state = %{
      run: nil,
      record: record,
      logging: logging,
      # The run's summary, folded as its episodes end rather than kept as reports:
      # 5 110 reports are 4.3 GB (measured on the live node) for a summary of a few
      # hundred bytes, and the transcript a reader wants is `RunStream`'s.
      summary: %Summary{},
      conclusion: %{},
      episode: 0,
      # Which pass over the phase's objects the run is on. Monty's sampler reads
      # it: `Predefined` walks its rotations one per epoch, so an epoch is what a
      # run of three sees as upright, then turned, then upright again.
      epoch: 0,
      # How many episodes this run has started. It, not the epoch's own index, is
      # the number the record keeps: see `start_episode/5`. A part's steps carry
      # the episode of the *experiment* they took, so the parts of one run make one
      # chart rather than four charts that each count from nought.
      episodes_started: offset_of(record),
      mode: :eval,
      # What the phase has learned so far, by module. A run is one episode, so
      # this is the memory a training phase carries from one to the next; an
      # evaluation phase writes nothing into it and hands it on unchanged.
      #
      # An evaluation wave of a parallel batch starts from the memory its training
      # wave's parts built between them, which is what the record points at.
      memories: memories_of(record, opened),
      # Where each object stood the first time this run showed it. A supervised
      # experiment states its answer as "here on the model", and a later epoch
      # that places the object somewhere else still extends the graph it built
      # the first time.
      first_seen: %{},
      # When this run last said it was alive, in monotonic seconds; `nil` until
      # the first step does. A record is written at episode boundaries and the
      # Reaper reads a silent record as a dead run, so the steps between two
      # boundaries have to say something while they work.
      beat: nil,
      # What the learning modules last said they believed. A step they were not
      # given cannot change it, so this is what such a step reports instead of
      # asking every module again.
      beliefs: %{},
      # What the last episode boundary cost, part by part, in microseconds: the
      # closing times its own work and the next episode's start appends its own,
      # and together they are the line `boundary_line/1` says. A boundary is half
      # of a run's wall clock and nothing about it is visible in a step's timer.
      boundary: []
    }

    {outcome, ran, state} =
      run_phases(plan, episodes_plan(record, episodes), state, %{
        experiment: experiment,
        objects: objects,
        pre_episode: &start_episode(run_id, opened, &1, &2, &3, &4),
        ground_truth: &ground_truth(&1),
        step: &step_once(run_id, &1, sensor_ids),
        finished?: fn %{run: run} -> Run.finished?(run) end,
        stopped?: fn -> stop_requested?(run_id) end,
        post_episode: &end_episode(run_id, &1, &2, &3)
      })

    say(run_id, episodes_line(ran))

    # The phase's model outlived its episodes and does not outlive the run: a
    # concluded run, a stopped one and a crashed one all release it here, where
    # the loop has returned whatever ended it.
    release_models(run_id, opened)

    # A part of a batch keeps its memory to its own directory: the library is what
    # the parts learned between them, and one part writing it would overwrite the
    # merged one with its own share.
    Enum.each(
      Learned.keep(run_id, opened, plan, state.memories, library: not part?(record)),
      &say(run_id, &1)
    )

    # A part of a run leaves its record to the run: the run knows when every part
    # is done and what the experiment concluded between them, and a part that
    # closed the row would say "finished" while its neighbours were still
    # stepping. Its summary goes with its outcome, because a run of four parts is
    # one run and a page that shows four parts' steps shows one number
    # (`Summary.merge/2`).
    if part?(record) do
      {outcome, state.summary}
    else
      close(state.record, opened, outcome, state.summary, state.conclusion, run_id)
    end
  end

  # -- a run of several parts ------------------------------------------------

  # Monty's `run_parallel.py`, as one job: the experiment divided into parts that
  # run at the same time (`Monty.Studio.Partition`), and one record for all of
  # them.
  #
  # The parts are processes inside this job rather than jobs of their own. A
  # part's work is independent of every other part's, so `Task.async_stream/3` is
  # `mp.Pool(num_parallel)`: it starts `n` of them, starts the next as one
  # finishes, and hands each back when it is done. What a part leaves behind is
  # its stream — its steps, its log, its memory — under the stream id the record
  # gave it, so four parts cannot overwrite each other's episode one or their
  # memory, and the row is written by this one process, which is what makes the
  # transcript append rather than race.
  #
  # Training then evaluation is Monty's `post_parallel_train`: the parts of the
  # training wave each build the memory of the objects they were given, the
  # memories are merged into one, and the evaluation wave starts from that one
  # (`Monty.Studio.Memories`).
  defp run_partitioned(record, opened, count) do
    run_id = record.id
    log_ready = Artifacts.start(run_id)
    record = attach_log(record, run_id, log_ready)
    parts = planned(record)

    # The division is a row per part before any of them starts: how many there
    # are, and — as each is taken — where it is performed. A run of one part has
    # no division to record.
    #
    # The division also starts with no parts on disk: a run performed once and
    # performed again begins its transcript again, and a part file left by the
    # first attempt is not this one's steps.
    if length(parts) > 1 do
      Artifacts.clear_parts(run_id)
      RunHistory.plan_parts(run_id, parts)
    end

    say(
      run_id,
      "run started: #{record.experiment}, #{length(parts)} part(s) of one experiment, " <>
        "#{min(count, length(parts))} at a time, up to #{record.steps} steps an episode"
    )

    broadcast(run_id, {:started, record.steps})

    {outcome, record, summary} =
      with {:ok, record, memories, trained} <- train_wave(record, opened, parts),
           {:ok, record, _memories, carried} <-
             eval_wave(record, opened, parts, memories, trained) do
        {:finished, record, carried}
      else
        {:error, reason, record, carried} -> {{:failed, reason}, record, carried}
        {:stopped, record, carried} -> {:stopped, record, carried}
      end

    # The division closes with the run, before anything reads it: a part that
    # started and never finished, or one the waves never reached, must not be left
    # saying it is still queued or running about a run that has ended.
    RunHistory.settle_parts(run_id)

    # The parts' steps are the run's transcript, written once and in part order,
    # and only then are the streams let go: they are the only copy until then.
    record = store_parts(record, parts)
    Enum.each(parts, &RunStream.clear(&1.stream))

    # What the parts wrote as statistics belongs to the run: each part has its
    # own `eval_stats.csv` in its own directory, and the run's directory is where
    # a reader looks for the experiment's own numbers. Monty's `run_parallel.py`
    # merges them for the same reason. Merged whatever the outcome: the parts
    # that finished wrote episodes that are real.
    _ = Artifacts.merge_reports(run_id, Enum.map(parts, & &1.stream))

    close(record, opened, outcome, summary, %{}, run_id, true)
  end

  # The training wave, and the memory it built between its parts.
  defp train_wave(record, opened, parts) do
    case wave(parts, "train") do
      [] ->
        {:ok, record, nil, %Summary{}}

      wave ->
        case run_wave(record, opened, wave, nil) do
          {:ok, record, carried} ->
            case merge_memories(record, opened, wave) do
              {:ok, record, memory} -> {:ok, record, memory, carried}
              {:error, reason, record} -> {:error, reason, record, carried}
            end

          {:error, reason, record, carried} ->
            {:error, reason, record, carried}

          {:stopped, record, carried} ->
            {:stopped, record, carried}
        end
    end
  end

  defp eval_wave(record, opened, parts, memories, trained) do
    case wave(parts, "eval") do
      [] ->
        {:ok, record, memories, trained}

      wave ->
        case run_wave(record, opened, wave, memories) do
          {:ok, record, carried} ->
            {:ok, record, memories, Summary.merge(trained, carried)}

          {:error, reason, record, carried} ->
            {:error, reason, record, Summary.merge(trained, carried)}

          {:stopped, record, carried} ->
            {:stopped, record, Summary.merge(trained, carried)}
        end
    end
  end

  # Monty's `post_parallel_train`: every part's memory read back, folded into one
  # (`Monty.Studio.Memories.merge/1`), written where the evaluation wave will look
  # for it — and where a later configuration of the same experiment looks, which
  # is what "the model was trained" means here.
  defp merge_memories(record, opened, wave) do
    memories = wave |> Enum.map(& &1.stream) |> Memories.learned(opened) |> Memories.merge()

    case Memories.keep(record.id, opened, memories) do
      {:ok, name} ->
        say(record.id, "merged #{length(wave)} trained part(s) into #{name}")

        memory = %{
          "name" => name,
          "release" => Learned.release(),
          "dir" => Memories.batch_dir(record.id)
        }

        {:ok, record, memory}

      {:error, reason} ->
        {:error, "the merged memory could not be written: #{inspect(reason)}", record}
    end
  end

  # One pass over a wave: `n` parts at a time, each writing its own stream, the
  # run's transcript written as each part falls out of the pool.
  defp run_wave(record, opened, wave, memory) do
    if stop_requested?(record.id) do
      # A stop that arrived before this wave started: not one part of it steps,
      # and the parts it would have stepped stay `queued` until the run settles
      # them as `skipped` — nothing happened to them, which is the truth about a
      # wave that never ran. Nothing was added to the run either.
      {:stopped, record, %Summary{}}
    else
      step_wave(record, opened, wave, memory)
    end
  end

  defp step_wave(record, opened, wave, memory) do
    results =
      wave
      |> hosts_for(record)
      |> Task.async_stream(
        fn {part, host} -> run_part(record, opened, part, memory, host) end,
        max_concurrency: max(length(wave), 1),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.to_list()

    record = Enum.reduce(results, record, fn result, record -> collect(result, record) end)
    carried = carried(results)

    case Enum.find(results, &broken?/1) do
      {:ok, {:error, part, reason, _steps}} ->
        {:error, "part #{part.index + 1} of #{part.of} stopped: #{inspect(reason)}", record,
         carried}

      nil ->
        if Enum.any?(results, &stopped?/1),
          do: {:stopped, record, carried},
          else: {:ok, record, carried}
    end
  end

  # What the parts of this wave added to the run: one summary between them, and
  # the episodes they concluded. A part that failed or was stopped before it
  # began contributes what it got through, which is the truth about the work.
  defp carried(results) do
    Enum.reduce(results, %Summary{}, fn
      {:ok, {:ok, _part, {_outcome, summary}, _steps}}, carried -> Summary.merge(carried, summary)
      _nothing, carried -> carried
    end)
  end

  defp broken?({:ok, {:error, _part, _reason, _steps}}), do: true
  defp broken?(_result), do: false

  # A part that ended in a stop rather than in the work it was given: the wave it
  # is in ends there too, because the run has been asked to stop, and the parts
  # that had not started are `skipped` when the run settles.
  defp stopped?({:ok, {:ok, _part, {outcome, _summary}, _steps}}), do: outcome == :stopped
  defp stopped?(_result), do: false

  # A part that has finished says so, and leaves its steps where they are: the
  # run's transcript is the parts' transcripts one after another, written once
  # when the run closes (`store_parts/2`), because a row holds one transcript and
  # four parts each writing theirs is four parts overwriting one another.
  #
  # The step count is the part's own answer: it is the number of steps it kept
  # (`keep_steps/2`), which for a part performed by a peer is a file's lines here
  # and nothing in this node's stream.
  defp collect({:ok, {:ok, part, {outcome, _summary}, steps}}, record) do
    say(record.id, "part #{part.index + 1} of #{part.of} #{status_of(outcome)}: #{steps} step(s)")
    record
  end

  # A part that failed took the steps it took before it did, and the row says so:
  # a division whose failed part reads "0 step(s)" is a part that appears not to
  # have started, which is the other half of what a reader is counting.
  defp collect({:ok, {:error, part, reason, steps}}, record) do
    say(
      record.id,
      "part #{part.index + 1} of #{part.of} failed after #{steps} step(s): #{said(reason)}"
    )

    record
  end

  defp collect({:exit, reason}, record) do
    say(record.id, "a part exited: #{said(reason)}")
    record
  end

  # A reason, as the run's own log says it. `Failure` keeps a crash as a sentence
  # with the traceback beside it, and the sentence is the half that belongs in a
  # transcript a person reads — pasting the pair here put a whole stack into the
  # log the page shows. The answers only a division gives are tags (a node, a
  # status, a position), which is the one thing `inspect` is good for.
  defp said(%{"reason" => sentence}) when is_binary(sentence), do: sentence
  defp said(reason), do: inspect(reason)

  # The one transcript a run of several parts leaves: part one's steps, then part
  # two's, and so on — which is the order Monty's dashboard draws its sections in,
  # and the order a reader of the record expects.
  #
  # The steps are read from the parts' own files, which every part writes when it
  # ends (`keep_steps/2`) — including a part this node performed, so the reader is
  # the same whatever performed the part. A run of several parts may therefore be
  # divided across the nodes that share its directory, and its transcript is still
  # one transcript.
  defp store_parts(record, parts) do
    {log, timeline} =
      parts
      |> Enum.sort_by(&{&1.phase, &1.index})
      |> Enum.flat_map(&part_transcript(record.id, &1))
      |> Enum.unzip()

    publish(record.id, {:keeping, length(log)})

    case RunWriter.store(record, log, timeline) do
      {:ok, saved} ->
        publish(record.id, :kept)
        saved

      {:error, reason} ->
        publish(record.id, :kept)
        say(record.id, "the run's steps could not be written: #{inspect(reason)}")
        record
    end
  end

  # One part's steps, in the order it took them: what it wrote for its run, or —
  # for a part this node performed whose file could not be written — the stream it
  # is still held in. A part performed by a peer has no stream here: its file is
  # the only copy, and a part with neither contributes nothing, which is the truth
  # about a part that never ran.
  defp part_transcript(run_id, part) do
    case Artifacts.read_part(run_id, part.phase, part.index) do
      {:ok, {entries, moments}} ->
        Enum.zip(entries, moments)

      {:error, _no_file} ->
        {entries, moments} = RunStream.steps(part.stream)
        Enum.zip(entries, moments)
    end
  end

  # One part, performed by the first node that can take it.
  #
  # A part is somebody's while it is being performed: the node it was given to
  # claims it in its row before the first step (`RunHistory.claim_part/3`), and the
  # claim is renewed as the part works. A node that stops answering loses the
  # claim when its lease lapses, and the part goes to the next candidate — one
  # owner at a time, which is the difference between a recovery and two runs of one
  # experiment overlapping (`Monty.Studio.Claim`).
  defp run_part(record, opened, part, memory, [host | rest]) do
    case attempt(record, opened, part, memory, host) do
      {:done, result} ->
        result

      # The node had the part and stopped answering. The row goes back to
      # `queued` — the part is unfinished, not failed — and the next node takes
      # it. A node that comes back still holds the old token, and the row does
      # not, so what it writes afterwards is refused.
      {:lost, claim, name, reason} when rest != [] ->
        _ = forget(claim)
        [next | _] = rest

        say(
          record.id,
          "part #{part.index + 1} of #{part.of} lost #{name} (#{inspect(reason)}); " <>
            "#{next.name} takes it"
        )

        run_part(record, opened, part, memory, rest)

      # Nobody is left to give it to: the part failed, and it failed with the
      # death of the node that had it.
      {:lost, claim, name, reason} ->
        settle(
          record,
          part,
          claim,
          {:error, part, {:peer_failed, name, reason}, steps_on_disk(record.id, part)}
        )
    end
  end

  defp run_part(_record, _opened, part, _memory, []) do
    {:error, part, {:no_node_for_part, part.index}, 0}
  end

  # Taking the part, performing it, and writing down how it ended — the three
  # things that make a part an object with an owner rather than a function call.
  defp attempt(record, opened, part, memory, host) do
    case claim(record.id, part, host) do
      {:ok, claim} ->
        task = Task.async(fn -> perform(record, opened, part, memory, host) end)

        case await(task, claim, part) do
          {:error, ^part, {:peer_failed, name, reason}, _steps} ->
            {:lost, claim, name, reason}

          result ->
            settle(record, part, claim, result)
            {:done, result}
        end

      # Somebody has this part: it is not this wave's to perform, and performing
      # it anyway is the duplicate the claim exists to refuse.
      {:error, reason} ->
        say(
          record.id,
          "part #{part.index + 1} of #{part.of} is not this run's to take: #{inspect(reason)}"
        )

        {:done, {:error, part, {:unclaimable, reason}, steps_on_disk(record.id, part)}}
    end
  end

  defp perform(record, opened, part, memory, host) do
    if host.node == node() do
      run_part_here(record, opened, part, memory, record.id)
    else
      run_part_there(record, part, memory, host)
    end
  end

  # Waits for the part, and keeps the claim alive while it waits.
  #
  # A part is minutes to hours of work, and a claim nobody renews is a part the
  # cluster is entitled to give to somebody else — so the renewal is part of the
  # wait, not something the part has to remember to do. Asking a third of the
  # lease ahead means a renewal that is missed twice still lands before the claim
  # lapses.
  defp await(task, claim, part) do
    case Task.yield(task, renew_every()) do
      {:ok, answer} ->
        answer

      {:exit, reason} ->
        {:error, part, Failure.crashed(:exit, reason, []), 0}

      nil ->
        case renew(claim) do
          :ok ->
            await(task, claim, part)

          # The part was given away while this node worked on it: stopping is the
          # only honest answer, because whatever this work concludes is about a
          # part somebody else has now.
          {:error, :lapsed} ->
            _ = Task.shutdown(task, :brutal_kill)
            {:error, part, {:lease_lost, claim_node(claim)}, 0}
        end
    end
  end

  defp renew_every, do: div(Monty.Studio.Claim.ttl_seconds() * 1000, 3)

  # A run of one part has no division to record, so there is nothing to claim: the
  # run's own row says the node has it.
  defp claim(run_id, part, host) do
    if part.of > 1, do: RunHistory.claim_part(run_id, part.index, host.name), else: {:ok, nil}
  end

  defp renew(nil), do: :ok
  defp renew(%Claim{} = claim), do: RunHistory.renew_claim(claim)

  # Whose claim it is: the node the part was given to. Only reached for a claim
  # that lapsed or was taken away, which a run of one part — a run with no division
  # and so nothing to claim — cannot have.
  defp claim_node(%Claim{node: holder}), do: holder

  defp release(nil, _status, _steps), do: :ok
  defp release(%Claim{} = claim, status, steps), do: RunHistory.release_part(claim, status, steps)

  defp forget(nil), do: :ok
  defp forget(%Claim{} = claim), do: RunHistory.abandon_part(claim)

  # How the part ended is the part's own answer, and the row may only be written
  # by the node that still holds it: a node whose claim was given away is told so
  # rather than allowed to overwrite the new owner's work.
  defp settle(record, part, claim, result) do
    {status, steps} = verdict(result)

    case release(claim, status, steps) do
      :ok ->
        :ok

      {:error, :not_owner} ->
        say(
          record.id,
          "part #{part.index + 1} of #{part.of}: #{claim_node(claim)} lost it while it " <>
            "worked, so its #{status} was refused"
        )
    end

    result
  end

  defp verdict({:ok, _part, {outcome, _summary}, steps}), do: {status_of(outcome), steps}
  defp verdict({:error, _part, _reason, steps}), do: {"failed", steps}

  # A part that never got to write its file — the node died before it finished a
  # step — left no steps, and the file is the only copy a peer's part has.
  defp steps_on_disk(run_id, part) do
    case Artifacts.read_part(run_id, part.phase, part.index) do
      {:ok, {entries, _moments}} -> length(entries)
      {:error, _no_file} -> 0
    end
  end

  # A part this node performs: the run the rest of this module already knows how
  # to step, with its own stream and the episodes it was given. Everything the
  # step loop derives from a record — the phase, the episodes, the memory — is
  # read from it here, so a part is not a second kind of run.
  defp run_part_here(record, opened, part, memory, run_id) do
    record = part_record(record, part, memory)
    # A part owns its stream the way a run owns its id: `Stop` reaches it, and the
    # Reaper can see that something is working on it, until it is done.
    register(record.id)

    outcome =
      try do
        case run_alone(record, opened) do
          {:error, reason} -> {:error, part, reason}
          outcome -> {:ok, part, outcome}
        end
      rescue
        exception -> {:error, part, Failure.crashed(:error, exception, __STACKTRACE__)}
      catch
        kind, reason -> {:error, part, Failure.crashed(kind, reason, __STACKTRACE__)}
      after
        unregister(record.id)
      end

    # The steps leave this node's memory with the part, and they leave it through
    # the run's directory: whatever performed this part, and however it ended, the
    # run's transcript can be read from what is on disk (`store_parts/2`).
    steps = keep_steps(run_id, part)

    case outcome do
      {:error, _part, reason} -> {:error, part, reason, steps}
      {:ok, _part, result} -> {:ok, part, result, steps}
    end
  end

  # A part another node performs. The record travels with the call: a node's runs
  # table is its own (`docs/cluster.md`), so a peer has no row for a run it does
  # not own, and what the part needs is everything the owner already knows. The
  # merged memory an evaluation part starts from travels as its description — a
  # directory in the run's own folder, which the peer reads because it is only a
  # candidate when it shares that folder.
  #
  # `:infinity` is the timeout because a part is minutes to hours of work, and a
  # peer that stops answering mid-part is a part that failed, not a run that
  # asked too early.
  defp run_part_there(record, part, memory, host) do
    case :rpc.call(
           host.node,
           __MODULE__,
           :perform_part,
           [
             record,
             part,
             memory,
             Protocol.local()
           ],
           :infinity
         ) do
      {:ok, result, steps} -> {:ok, part, result, steps}
      {:error, reason, steps} -> {:error, part, reason, steps}
      {:badrpc, reason} -> {:error, part, {:peer_failed, host.name, reason}, 0}
    end
  end

  @doc """
  Performs one part of a run **on this node**, for the node that owns the run.

  Called over `:rpc` (`run_part_there/4`), and called by a test directly: this is
  the whole of what a peer does for a part, so what a peer does is specified on
  one node.

  A part that ends here leaves its steps in the run's own directory
  (`Artifacts.store_part/5`), where the owner reads them for the run's transcript;
  the answer is only what the owner cannot read from a file — how the part ended
  and what it concluded.

  A peer answers only when it speaks the same protocol: a node of another build
  that was handed a record of a shape it does not know is refused here, by name,
  rather than half-way through the part.
  """
  @spec perform_part(map(), map(), map() | nil, map()) ::
          {:ok, term(), non_neg_integer()} | {:error, term(), non_neg_integer()}
  def perform_part(%RunHistory.Run{} = record, part, memory \\ nil, caller \\ Protocol.local()) do
    if Protocol.compatible?(caller) do
      case opened_for(record) do
        {:ok, opened} -> answer(run_part_here(record, opened, part, memory, record.id))
        # A peer that cannot open the experiment answers the same shape as a peer
        # that ran it and failed: the owner matches three-tuples, and a two-tuple
        # here was a `CaseClauseError` on the node that owns the run.
        {:error, reason} -> {:error, reason, 0}
      end
    else
      {:error,
       {:incompatible_peer, Protocol.describe(caller), Protocol.describe(Protocol.local())}, 0}
    end
  end

  # What the owner reads: how the part ended and what it concluded. The part is
  # not in the answer — the owner already has it.
  defp answer({:ok, _part, result, steps}), do: {:ok, result, steps}
  defp answer({:error, _part, reason, steps}), do: {:error, reason, steps}

  # Who performs each part of this wave, and the run says so before any of it
  # runs: the assignment is the cluster's answer to a question the run cannot ask
  # itself (`Monty.Studio.Partition.hosts/3`).
  defp hosts_for(wave, record) do
    hosts = Partition.hosts(wave, Nodes.snapshot(), Placement.needs(record.inputs))

    for {part, [host | _rest]} <- hosts, host.node != node() do
      say(record.id, "part #{part.index + 1} of #{part.of} is performed by #{host.name}")
    end

    hosts
  end

  # A part's steps, written where its run can read them.
  #
  # Most of them are already there: a part appends what it took at every episode
  # boundary (`keep/2`), so what is left is the tail after the last boundary — and
  # a part that failed or was stopped has a tail too, because the steps it took in
  # the episode it never finished are real.
  #
  # The count is the file's, not the stream's: a part performed by a peer has no
  # stream on this node, and a part that was resumed has the steps of both
  # attempts in one file.
  defp keep_steps(run_id, part) do
    # From what the file already holds, which is the cursor: the boundaries wrote
    # everything up to their last one, and what is left is the tail. Asking the
    # file rather than a counter in memory is also what makes a boundary whose
    # write failed cost a duplicate of nothing rather than a lost episode.
    written = Artifacts.part_steps(run_id, part.phase, part.index)
    {entries, moments} = RunStream.steps_from(part.stream, written - 1)

    case Artifacts.append_part(run_id, part.phase, part.index, entries, moments) do
      :ok ->
        Artifacts.part_steps(run_id, part.phase, part.index)

      {:error, reason} ->
        # The stream still holds them and `part_transcript/2` falls back to it,
        # but a part performed by a peer has no stream here — so this line is the
        # one that says a division lost its steps.
        say(
          run_id,
          "part #{part.index + 1} of #{part.of}: its steps could not be kept: #{inspect(reason)}"
        )

        length(entries)
    end
  end

  defp part_record(record, part, memory) do
    %{
      record
      | id: part.stream,
        inputs:
          Map.put(record.inputs, "part", %{
            "index" => part.index,
            "of" => part.of,
            # The run this part belongs to: the row it is recorded in, the log it
            # writes to and the directory its pictures are served from are all the
            # run's, because a part's stream id is a stream and not a run
            # (`db/1`).
            "parent" => record.id,
            # The phase as a word, so the boundary that appends a part's steps
            # knows which file to append them to without reading the plan.
            "phase" => to_string(part.phase),
            "phases" => %{to_string(part.phase) => remaining(record.id, part)},
            "memory" => memory
          })
    }
  end

  # The episodes a part still has to take: its own, less the ones it already
  # finished.
  #
  # A part given to a second node after the first went silent picks up where it
  # stopped rather than starting its stretch again — the episodes it finished are
  # on disk with their steps (`Artifacts.append_part/6`), so taking them twice
  # would be work duplicated and a transcript with two copies of them.
  #
  # Only an evaluation part resumes. A training part's episodes build on each
  # other — the graph one made is the graph the next extends — and the model that
  # took them did not travel with the part.
  defp remaining(run_id, %{phase: :eval} = part),
    do: Enum.drop(part.episodes, Artifacts.progress(run_id, part.phase, part.index))

  defp remaining(_run_id, part), do: part.episodes

  # The plan the record was started with (`Monty.Studio.Partition`), as parts.
  defp planned(%{inputs: %{"parts" => [_ | _] = parts}}) do
    Enum.map(parts, fn part ->
      %{
        index: part["index"],
        of: part["of"],
        phase: phase_of(part["phase"]),
        episodes: part["phases"] |> Map.values() |> List.flatten(),
        stream: part["stream"]
      }
    end)
  end

  defp planned(_no_plan), do: []

  defp wave(parts, phase), do: Enum.filter(parts, &(to_string(&1.phase) == phase))

  defp phase_of("train"), do: :train
  defp phase_of("eval"), do: :eval
  defp phase_of(_other), do: :eval

  # The row a part writes to: the run's own, never the stream's. A part's id is
  # where its steps and its memory live, not where the experiment is recorded.
  defp db(%{inputs: %{"part" => %{"parent" => parent}}} = record) when is_binary(parent),
    do: %{record | id: parent}

  defp db(record), do: record

  defp parallel(%{inputs: %{"parallel" => count}}) when is_integer(count) and count > 1, do: count
  defp parallel(_one), do: 1

  # A part's steps go on the run's topic, because the page watching the run
  # draws every part; a step says which part took it, which is how the run's own
  # chart keeps them apart and how a part's card finds its own.
  defp announce_of(record), do: db(record).id

  defp part_index(%{inputs: %{"part" => %{"index" => index}}}), do: index
  defp part_index(_whole_run), do: nil

  # Monty's `run()`: `train()` and then `evaluate()`, each a loop of its own with
  # the mode set on the model before it starts. An epoch that ends badly ends the
  # run, because the next phase would step a model that is not there.
  defp run_phases([{mode, epochs} | rest], episodes, state, callbacks) do
    {outcome, ran, state} =
      callbacks.experiment.run_epochs(
        %{state | mode: mode},
        callbacks
        |> Map.put(:objects, Map.get(callbacks.objects, mode, []))
        |> Map.merge(%{epochs: epochs, episodes: episodes_for(episodes, mode)})
      )

    case outcome do
      :finished when rest != [] ->
        {later, more, state} = run_phases(rest, episodes, state, callbacks)
        {later, ran ++ more, state}

      finished_or_ended ->
        {finished_or_ended, ran, state}
    end
  end

  defp run_phases([], _episodes, state, _callbacks), do: {:finished, [], state}

  # "2 object(s) to train on, 1 to evaluate", which is not always one number.
  defp objects_line(objects) do
    Enum.map_join([:train, :eval], ", ", fn mode ->
      "#{length(Map.get(objects, mode, []))} to #{if mode == :train, do: "train on", else: "evaluate"}"
    end)
  end

  # "3 train epoch(s) then 14 eval epoch(s)", in the words the record uses.
  defp phases_line([]), do: "no epochs: the config switches both phases off"

  defp phases_line(plan) do
    plan
    |> Enum.map_join(" then ", fn {mode, epochs} -> "#{epochs} #{mode} epoch(s)" end)
  end

  defp episodes_of(%{inputs: %{"episodes" => count}}, _default)
       when is_integer(count) and count > 0,
       do: count

  defp episodes_of(_record, default), do: default

  # The episode a part starts counting from: the first of the episodes it was
  # given. A run of the whole experiment starts at nought.
  defp offset_of(%{inputs: %{"part" => %{"phases" => phases}}}) when is_map(phases) do
    phases |> Map.values() |> List.flatten() |> Enum.min(fn -> 0 end)
  end

  defp offset_of(_whole_run), do: 0

  # The part of a parallel batch this run is, or `nil` for a run of the whole
  # experiment (`Monty.Studio.Partition`).
  defp part(%{inputs: %{"part" => %{} = part}}), do: part
  defp part(_record), do: nil

  defp part?(record), do: part(record) != nil

  # What a part takes, phase by phase, as the loop's own vocabulary: the episode
  # numbers of that phase and nothing else. A run of the whole experiment answers
  # the budget it was given, which is the same thing said as a count.
  defp episodes_plan(record, budget) do
    case part(record) do
      nil ->
        budget

      %{"phases" => phases} ->
        Map.new(phases, fn {mode, indices} -> {phase(mode), {:indices, indices}} end)
    end
  end

  defp episodes_for(episodes, mode) when is_map(episodes),
    do: Map.get(episodes, mode, {:indices, []})

  defp episodes_for(episodes, _mode), do: episodes

  defp phase("train"), do: :train
  defp phase("eval"), do: :eval
  defp phase(:train), do: :train
  defp phase(:eval), do: :eval

  # The plan a run is walked with: the config's phases and how many epochs of each,
  # or — for a part of a parallel batch — the phases that part was given, one pass
  # each. A part that was told to train does not run the config's evaluation as
  # well: its work is the episodes it was handed (`Monty.Studio.Partition`).
  defp phases_of(record, setup) do
    case part(record) do
      nil ->
        Setup.epoch_plan(setup)

      %{"phases" => phases} ->
        for mode <- [:train, :eval],
            Map.get(phases, to_string(mode)) not in [nil, []],
            do: {mode, 1}
    end
  end

  # What the run starts from: the memory its record points at — an evaluation
  # wave's merged one — or the library its config names.
  defp memories_of(%{inputs: %{"part" => %{"memory" => %{} = pointer}}}, opened),
    do: Memories.load(opened, pointer)

  defp memories_of(_record, opened), do: Setup.memories(opened.setup)

  # Monty's `pre_episode`, interface half: an episode starts where it was told to
  # — the world for this episode's object, the agent positioned, the sensors
  # reset. The previous episode's processes go first, because a run steps one
  # world at a time.
  # Monty's `pre_episode`, interface half: an episode starts where it was told to
  # — the world for this episode's object, the agent positioned, the sensors
  # reset. The previous episode's processes go first, because a run steps one
  # world at a time.
  #
  # `index` is the episode's place *within its epoch*, and the epoch restarts it:
  # a run of three train epochs then three evaluation ones has six episodes and
  # only three indices. It seeds the episode (`Run.start/2` derives the draws from
  # it) and it is what the log line names, Monty's own way. What the record keeps
  # is the run's own episode — `episodes_started` — because a chart stacks the
  # episodes of a run and two of them sharing a number would be drawn as one: a
  # line joining the last step of the training phase to the first of the
  # evaluation one, across a boundary where the evidence really did restart.
  defp start_episode(run_id, opened, %{run: previous} = state, index, object, callbacks) do
    episode = state.episodes_started

    # The previous episode's world goes first, because a run steps one world at a
    # time. Its model stays: an evaluation phase steps the model it has.
    stop_world(previous)

    # The episode is built from its own phase's objects: the world it shows, the
    # semantic id it carries and the target it is judged by all come from the
    # interface Monty would have used for this mode. An evaluation phase steps the
    # model it already has; a training phase's next episode starts from the memory
    # the last one wrote, so it is given a model of its own (`phase_model_id/1`).
    options = [
      steps: state.record.steps,
      episode: index,
      epoch: Map.get(callbacks, :epoch, 0),
      mode: state.mode,
      memory: state.memories,
      first_seen: state.first_seen,
      has_detailed_logger: Logging.detailed?(state.logging)
    ]

    options =
      if state.mode == :eval, do: [{:model_id, phase_model_id(run_id)} | options], else: options

    case Run.start(Setup.with_phase(opened.setup, state.mode), options) do
      {:ok, run} ->
        Registry.update_value(Monty.Runtime.Registry, key(run_id), fn _ -> run.model_id end)
        say(run_id, "episode #{index + 1}: #{object || "the scene's own object"}")

        # The closing timed the rest and the start timed its own parts; a first
        # episode has no boundary behind it to report.
        if state.boundary != [],
          do: say(run_id, boundary_line(state.boundary ++ run.started_in))

        broadcast(
          run_id,
          {:episode, %{episode: episode, object: object, steps: state.record.steps}}
        )

        {:ok,
         %{
           state
           | run: run,
             episode: episode,
             episodes_started: episode + 1,
             beliefs: %{},
             boundary: []
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Monty's `pre_episode`, experiment half: what the world chose, told to the
  # model, so a step can name the object under the patch.
  defp ground_truth(%{run: run} = state) do
    :ok = Run.set_ground_truth(run)
    {:ok, state}
  end

  # Monty's `post_episode`: the episode is logged, then the memory it produced is
  # written, and then its processes go. The order matters — the episode is logged
  # *before* the write, because that write rewrites the episode's ground truth
  # and an episode logged afterwards would look confused about the object it just
  # recognised (`monty_experiment.py`, `post_episode`).
  defp end_episode(run_id, %{run: run} = state, outcome, infos) do
    {conclusion, memories, logging, closing} = close_episode(run_id, state, outcome, run)

    {stopping, _} = :timer.tc(fn -> stop_episode(run, state, outcome) end)
    {handed, record} = :timer.tc(fn -> keep(state.record, state.episodes_started - 1) end)

    # `infos` arrive newest first; the fold does not care about order, but the
    # report a reader gets is written oldest first, so it is the same list either
    # way — and the episode's reports are released as soon as they are folded.
    %{
      state
      | run: nil,
        record: record,
        summary:
          Summary.accrue(Enum.reverse(infos), state.summary)
          |> tally(conclusion),
        conclusion: conclusion,
        memories: memories,
        logging: logging,
        boundary: closing ++ [{"stop", stopping}, {"hand-over", handed}],
        # A supervised episode names where the object stood, and that place is
        # what every later episode of this run extends (`Run.supervise/1`).
        first_seen: run.first_seen
    }
  end

  # What the end of an episode owes its run's tally: one more conclusion, under
  # the module that made it. The last episode is not the run — whether this port
  # recognises what Monty recognises is a question about all of them — so a run
  # keeps a count per module, which is what the page's "across the run" line and
  # `mix monty.run` both read.
  defp tally(summary, conclusion),
    do: %{summary | outcomes: Summary.tally(summary.outcomes, conclusion)}

  # What the end of an episode owes — its statistics, its conclusion and, when it
  # trained, the memory it left — with what each part cost. A part nobody timed is
  # a part nobody can argue about, and the boundary is half of a run's wall clock.
  #
  # Both the statistics and the conclusion are made of the model's state, so it is
  # read once. What is read is `episode_state/2`: each module's own projection for
  # a BASIC report, the whole model for a DETAILED one.
  defp close_episode(run_id, state, outcome, run) do
    cond do
      crashed?(outcome) ->
        # The crash took the model with it: a module's failure stopped the step
        # the model is, and both the statistics and the conclusion are read off
        # that model. The reason this run ends is the crash, said once with its
        # own traceback — asking a dead process for the rest would replace it
        # with "a process the run was waiting on exited". Nothing was learned,
        # so the phase keeps the memory it had.
        say(run_id, "the episode crashed, so its statistics were not read")
        {%{}, state.memories, state.logging, []}

      state.mode == :train ->
        {read, model_state} = :timer.tc(fn -> episode_state(state, run) end)

        {recorded, logging} =
          :timer.tc(fn -> log_statistics(run_id, state.logging, run, model_state) end)

        {concluded, conclusion} = :timer.tc(fn -> Run.conclusion_of(model_state) end)
        {written, memories} = :timer.tc(fn -> learned(run_id, run, state.memories) end)
        # A matching run is judged by evidence climbing per object; a training
        # run matches nothing, so what it has to show is the memory it built.
        say(run_id, Learned.growth_line(memories))

        {conclusion, memories, logging,
         [
           {"model state", read},
           {"statistics", recorded},
           {"conclusion", concluded},
           {"memory", written}
         ]}

      true ->
        # An evaluation episode writes nothing, and this reads nothing either:
        # the memory only has to travel when something wrote to it, and
        # reading it back copies tens of megabytes out of the module process
        # every episode (`LearningModuleServer.state/1` — the reason
        # `detailed/2` exists).
        {read, model_state} = :timer.tc(fn -> episode_state(state, run) end)

        {recorded, logging} =
          :timer.tc(fn -> log_statistics(run_id, state.logging, run, model_state) end)

        {concluded, conclusion} = :timer.tc(fn -> Run.conclusion_of(model_state) end)

        {conclusion, state.memories, logging,
         [{"model state", read}, {"statistics", recorded}, {"conclusion", concluded}]}
    end
  end

  # The state an episode's statistics are read from, decided by the plan: a BASIC
  # report reads a dozen fields of each module, a DETAILED one reads the module.
  # Either way the modules are asked in their own processes, so what is reported
  # is the episode that has just been taken rather than the one the model was
  # started for (`Monty.Studio.Logging.state/2`).
  defp episode_state(state, run), do: Logging.state(run, state.logging)

  # The record in hand is the transcript; writing it is what makes it history.
  # A write that fails does not stop a run: the steps are still in memory for the
  # page, and the next boundary tries again.
  #
  # A part writes nothing to the record: its steps are the run's, and the run
  # writes them to the database when it settles (`collect/2`). Four parts keeping
  # a cursor of their own on one column was four parts rewriting each other's
  # transcript.
  #
  # It writes to its own file, though, and at every boundary: the steps it has
  # taken since the last one, and the fact that this episode finished. That is
  # what makes a part resumable — the next node to have it starts at its first
  # unfinished episode (`remaining/2`) — and what keeps a node that dies from
  # taking the part's transcript with it.
  defp keep(%{inputs: %{"part" => %{"phase" => phase} = part}} = record, episode) do
    # `steps_from/2` reads the steps *after* the position it is given, and a step's
    # position is its place from nought — so the last one written is `count - 1`,
    # and a part that has written nothing asks from `-1`, which is every step.
    {entries, moments} = RunStream.steps_from(record.id, (record.steps_done || 0) - 1)

    case Artifacts.append_part(record.id, phase, part["index"], entries, moments, episode) do
      :ok -> %{record | steps_done: (record.steps_done || 0) + length(entries)}
      # The stream still holds them and the next boundary tries again: an episode
      # whose steps could not be written is a resume point one episode behind,
      # not a run that stops.
      {:error, _reason} -> record
    end
  end

  defp keep(record, _episode) do
    {saved, _held?} = keep_with_state(record)
    saved
  end

  # Whether the row now holds the steps decides whether the memory may be
  # dropped: it is the only copy until it is written.
  #
  # The write is handed to `RunWriter` rather than made here. Waiting for it was
  # 3.3 s an episode of a run's 84 (`59613a1c`): the model sat idle while
  # Postgres rewrote a quarter of a gigabyte, and nothing about the next episode
  # depended on the answer. The count of what has been handed over moves with the
  # hand-over, so the same steps are never asked for twice; a write that fails is
  # the writer's to retry, and the steps are still in memory for the page.
  #
  # What crosses is the transcript only. The pictures are five times its size and
  # every one of them would be rewritten by the statement that appends
  # (`RunHistory.store/3` explains the measurement), so they are written once, as
  # the run settles.
  defp keep_with_state(%{id: id, steps_done: written} = record) do
    {new_log, new_timeline} = RunStream.steps_from(id, written || 0)
    handed = (written || 0) + length(new_log)

    publish(id, {:keeping, handed})
    :ok = RunWriter.checkpoint(record, {new_log, new_timeline}, handed)
    publish(id, :kept)

    {%{record | steps_done: handed}, true}
  end

  defp publish(run_id, event),
    do: Phoenix.PubSub.broadcast(ExTbpMonty.PubSub, topic(run_id), {:studio, run_id, event})

  # Monty's `model.update_ltm()`: the module decides what a training episode adds
  # to long-term memory. What answers here is the memory the *rest* of the phase
  # starts from — the graph this episode built is what the next one matches
  # against — so it is read only where it can have changed (`Run.next_memories/3`).
  defp learned(run_id, run, memories) do
    Run.next_memories(run, memories, :train)
  rescue
    # A memory is what the episode leaves behind, not part of the episode: a
    # module that cannot answer for it must not turn a finished run into a crash.
    error ->
      say(run_id, "the memory could not be written: #{Exception.message(error)}")
      memories
  end

  defp crashed?({:crashed, _step, _reason}), do: true
  defp crashed?(_outcome), do: false

  # The closing write: the whole transcript and every step's pictures, in one
  # statement. A boundary writes the transcript alone (see `keep_with_state/1`),
  # because appending to a `jsonb` array rewrites the array — measured at 14.7 s
  # for an *empty* append to a 24 329-step row, which is what 140 boundaries of a
  # run that size were paying.
  defp store_all(%{id: id} = record) do
    {log, timeline} = RunStream.steps(id)
    publish(id, {:keeping, length(log)})

    case RunWriter.store(record, log, timeline) do
      {:ok, saved} ->
        publish(id, :kept)
        {saved, true}

      {:error, reason} ->
        publish(id, :kept)
        Logger.warning("studio run #{id}: cannot write its steps: #{inspect(reason)}")
        {record, false}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      publish(id, :kept)

      Logger.warning(
        "studio run #{id}: the closing write was abandoned, so its steps are only in " <>
          "memory for whoever is watching: #{Exception.message(error)}"
      )

      {record, false}
  end

  # An episode's own processes: its world goes every time, and its model goes
  # whenever the next episode cannot step it — a phase that learns writes the
  # memory a model is built from, so the next training episode starts from a new
  # one, and a crashed episode leaves a model nothing should step again.
  defp stop_episode(run, state, outcome) do
    stop_world(run)
    if state.mode == :train or crashed?(outcome), do: stop_model(run)
  end

  defp stop_world(nil), do: :ok
  defp stop_world(run), do: guard_tidying(fn -> Run.stop_world(run) end)

  defp stop_model(%{model: _model} = run), do: guard_tidying(fn -> Run.stop_model(run) end)

  defp guard_tidying(fun) do
    fun.()
  rescue
    # A world already closed is a world with nothing left to stop, and a model
    # already stopped is one too: stopping is tidying up, not a step that fails.
    _gone_already -> :ok
  end

  # The model an evaluation phase steps. One per run, because a model outlives the
  # episode it steps: `Run.start/2` resets a model it is given an id for, and
  # building one per episode cost 895 ms of the memory's graphs each time — half of
  # a ten-object run's wall clock. A training phase holds none, because what a
  # training episode learns is the memory the next model is built from.
  defp phase_model_id(run_id), do: "studio-#{run_id}-eval"

  defp release_models(run_id, opened) do
    model_id = phase_model_id(run_id)

    case Monty.Runtime.Registry.lookup({:model, model_id}) do
      [{_pid, _}] -> guard_tidying(fn -> Setup.model_class(opened.setup).stop(model_id) end)
      [] -> :ok
    end

    # The supervisor held the model's child spec, and with it the memory the model
    # was started from — the pretrained graphs, 203 MB — in its own heap.
    # Terminating the child drops the spec, but a BEAM process's heap is only
    # collected when it grows again, so that heap sits there looking like a leak:
    # measured after a finished run, 203 MB of it, and one collection took the node
    # from 319 MB to 95 MB against an 84 MB baseline. Asked for once a run, because
    # the next run's memory profile should not have to explain the last one's.
    case Process.whereis(ExTbpMonty.Core.ModelSupervisor) do
      pid when is_pid(pid) -> :erlang.garbage_collect(pid)
      _not_started -> :ok
    end
  end

  defp episodes_line(episodes) do
    ran =
      Enum.map_join(episodes, ", ", fn episode ->
        "#{episode.object || "scene"} #{episode.steps} steps (#{ending(episode.outcome)})"
      end)

    "#{length(episodes)} episode(s): #{ran}"
  end

  defp ending(:finished), do: "concluded"
  defp ending(:stopped), do: "stopped"
  defp ending({:crashed, step, _reason}), do: "failed at step #{step}"

  # A step either reports or the run is broken. A broken step is recorded with
  # the reason it died, because a page that says "running" for ever is a page
  # nobody trusts. What the loop does with that — and with a caller's stop — is
  # `MontyExperiment.run_episode_steps/2`, which is Monty's episode loop.
  defp step_once(run_id, %{run: run} = state, sensor_ids) do
    {:ok, info, observations, run} = Run.step(run)
    beliefs = beliefs_after(info, run, state.beliefs)

    # The world's own answer, not the transformations' — the transformed
    # observations say what the model was *given* (poses, curvatures, and for the
    # ports not even a location), and a picture of the object is what the world
    # rendered. An experiment behind the port records nothing drawable otherwise,
    # which is a replay of blank frames.
    rendered = Run.rendered_observations(run) || observations

    # The step itself is the only thing that has `info` and `beliefs`, so the
    # report is assembled here — and everything a page or a row makes of it, the
    # entry and the line included, is `RunStream`'s, handed over rather than
    # waited for. Formatting a step's line here cost 117 us a step and building
    # its entry another 509 (10 objects, surface agent); both are this
    # process's to do once the run has moved on.
    RunStream.publish(
      run_id,
      %{
        info: info,
        at: RunLog.now().instant,
        episode: state.episode,
        beliefs: beliefs,
        observations: rendered,
        sensor_ids: sensor_ids,
        centre: centre_view(run, info.step),
        part: part_index(state.record)
      },
      announce: announce_of(state.record)
    )

    # The record in this process is the counters: the transcript is the stream's,
    # and a boundary asks it for what the row has not written yet.
    {:ok, info,
     %{
       state
       | run: run,
         beliefs: beliefs,
         beat: RunHistory.heartbeat(state.record, state.beat)
     }}
  catch
    # A raise and an exit are the same thing here: the step did not produce a
    # report. Both end the episode as a failure, because the alternative — the
    # exception escaping the job — leaves a record saying "running" for ever,
    # and a page nobody trusts. The sentence is built here, where the traceback
    # still exists: formatted later from a bare term, it would have none.
    kind, reason -> step_died(run_id, run, Failure.crashed(kind, reason, __STACKTRACE__))
  end

  # What the modules hold after a step. A step the learning modules were not given
  # cannot change what they believe — reading it costs a call per module and a copy
  # of the module's own numbers, and 83 % of a surface-agent run's steps are that
  # step — so the beliefs are read when there is something new to read, and the one
  # read at the start of an episode gives the rest something to carry.
  defp beliefs_after(info, run, held) do
    if info.processed? or map_size(held) == 0,
      do: Run.beliefs(run),
      else: held
  end

  defp step_died(run_id, run, %{"reason" => what} = recorded) do
    say(run_id, "step #{run.step} died: #{what}")
    {:error, recorded}
  end

  # A run whose statistics did not get written has still run: the episode is
  # real, the file is missing. That is said in the run's log rather than raised,
  # because the failure is about the artefact and not about the experiment.
  # The plan that comes back is the logger with this episode counted and its
  # handlers' own bookkeeping moved on. It has to travel: a CSV handler renames a
  # file it has not written to yet, because a file that exists belongs to the last
  # run — so a plan thrown away here renames the run's own statistics away at every
  # episode and leaves one row, which is what every file in `studio_runs` had. A
  # report that failed leaves the plan as it was, so the next episode tries again
  # with the same answer rather than with half a file's worth of state.
  defp log_statistics(run_id, logging, run, model_state) do
    case Logging.report(logging, run, Artifacts.dir(run_id), model_state) do
      {:ok, reported} ->
        reported

      {:skipped, reported} ->
        reported

      {:error, reason} ->
        say(run_id, "statistics could not be written: #{inspect(reason)}")
        logging
    end
  end

  # The stop lands in this process's mailbox because this process owns the clock —
  # and, for the steps that happen in tasks it started, in `Stops`, because a
  # task's mailbox is its own: a stop that only asked the worker was read at the
  # next wave boundary, which for a run of one part is after a whole phase.
  defp stop_requested?(run_id) do
    receive do
      :stop -> true
    after
      0 -> Stops.asked?(run_id)
    end
  end

  # Where the agent is, relative to the object it is meant to be looking at. A
  # world with no scene has nothing to centre on and answers `nil`, which the page
  # reads as "no such panel".
  defp centre_view(run, step), do: CentreView.frame(run.interface.env, step)

  defp close(record, opened, outcome, summary, conclusion, run_id, written? \\ false) do
    summary = Summary.finish(summary, opened.setup, conclusion)
    status = status_of(outcome)
    # One summary for the record and for whoever is watching: why a run did not
    # finish is part of it, because that is everything a page has after the last
    # step.
    stored = RunLog.summary(summary, Failure.stopped(outcome))

    say(run_id, closing_line(outcome, summary))

    # The run's steps and its pictures go into the row once, here, rather than
    # once an episode while it ran. They stay in memory for a page until the row
    # has them. A run of several parts has already written them, part by part, as
    # each part fell out of the pool.
    {record, held?} = if written?, do: {record, true}, else: store_all(record)
    if held?, do: RunStream.clear(run_id)

    case RunHistory.finish(record, stored, status) do
      {:ok, record} ->
        broadcast(run_id, {:finished, %{status: status, summary: stored}})
        {:ok, record}

      {:error, changeset} ->
        say(run_id, "could not close the record: #{inspect(changeset.errors)}")
        broadcast(run_id, {:failed, %{reason: {:cannot_close, changeset.errors}}})
        {:cancel, {:cannot_close, changeset.errors}}
    end
  end

  defp status_of(:finished), do: "finished"
  defp status_of(:stopped), do: "stopped"
  defp status_of({:crashed, _step, _reason}), do: "failed"
  defp status_of({:failed, _reason}), do: "failed"

  defp closing_line(:finished, summary),
    do:
      "run finished: #{summary.steps} steps, #{summary.duration_us} µs in the model " <>
        "and #{summary.world_us} µs in the world"

  defp closing_line(:stopped, summary),
    do:
      "run stopped after #{summary.steps} step(s), #{summary.duration_us} µs in the model " <>
        "and #{summary.world_us} µs in the world"

  defp closing_line({:failed, reason}, summary),
    do: "run failed after #{summary.steps} step(s): #{reason}"

  defp closing_line({:crashed, step, reason}, summary) do
    what = reason |> Failure.stopped() |> Map.fetch!("reason")
    "run failed at step #{step} after #{summary.steps} step(s): #{what}"
  end

  # -- failing loudly enough -------------------------------------------------

  # A run whose worker raised has ended. Oban records the crash on the job, but
  # jobs are pruned and a person reads the run — so the sentence goes where the
  # run's own page shows it, the traceback beside it for whoever is debugging,
  # and only then is the exception let out, for the job's attempt to be counted.
  defp died(run_id, %{"reason" => what} = recorded) do
    Logger.error("studio run #{run_id} died: #{recorded["technical"] || what}")
    _ = Artifacts.start(run_id)
    _ = say(run_id, "the run died: #{what}")

    with {:ok, record} <- fetch(run_id),
         do: RunHistory.finish(record, Map.merge(record.summary || %{}, recorded), "failed")

    broadcast(run_id, {:failed, %{reason: what}})
  end

  defp give_up(run_id, reason) do
    Logger.error("studio run #{run_id} did not happen: #{inspect(reason)}")

    recorded =
      "The run could not start: its experiment would not open."
      |> Failure.explain(inspect(reason))
      |> Failure.recorded()

    with {:ok, record} <- fetch(run_id) do
      _ = Artifacts.start(run_id)
      _ = say(run_id, "run did not happen: #{recorded["reason"]}")
      _ = RunHistory.finish(record, Map.merge(record.summary || %{}, recorded), "failed")
    end

    broadcast(run_id, {:failed, %{reason: recorded["reason"]}})
    {:cancel, reason}
  end

  # A job's arguments are data, not a promise: an id that is not a run id is
  # answered with what it is, rather than with a cast error from the database.
  defp fetch(run_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id),
         %{} = record <- RunHistory.get(uuid) do
      {:ok, record}
    else
      :error -> {:error, {:not_a_run_id, run_id}}
      nil -> {:error, {:no_such_run, run_id}}
    end
  end

  # A run whose experiment no longer composes is not a run: say which one and
  # why, rather than starting something else and calling it the same thing.
  # The record is the contract: a run says which world it steps, and the queue
  # executes that, not whatever the worker's own environment happens to be. Two
  # processes can share the queue and this database, and one of them may have
  # Monty's world configured while the other does not.
  # The record keeps the world a run was started with; the job turns that back
  # into the world to step. A value this build does not carry is `nil`, which
  # `Monty.Studio.Setup` reads as "nothing chosen" — never a silent stand-in: a
  # run recorded as MuJoCo must not step a sphere.
  defp world_of(%{"world" => "mujoco"}), do: :mujoco
  defp world_of(%{"world" => "synthetic"}), do: :synthetic
  # A part is the one world this node may not carry. It is still the world the
  # record names, so the run refuses it — `Setup.world/4` says which application
  # is missing — rather than stepping this worker's own default and reporting
  # numbers for a run nobody asked for.
  defp world_of(%{"world" => "cad"}), do: :cad
  defp world_of(_inputs), do: nil

  defp attach_log(record, run_id, :ok) do
    path = Artifacts.log_path(run_id)

    case RunHistory.attach_log(db(record), path) do
      {:ok, written} -> %{record | log_path: written.log_path}
      {:error, changeset} -> fail_log(record, {:cannot_record_log_path, changeset.errors})
    end
  end

  defp attach_log(record, run_id, {:error, reason}) do
    Logger.error("studio run #{run_id}: no log directory: #{inspect(reason)}")
    fail_log(record, reason)
  end

  defp fail_log(record, reason) do
    Logger.error("studio run #{record.id}: #{inspect(reason)}")
    record
  end

  defp say(run_id, line) do
    case Artifacts.append(run_id, line) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("studio run #{run_id}: cannot write log: #{inspect(reason)}")
    end
  end

  # Where a boundary's time went, in the run's own log: an episode is separated
  # from the next by a second or two that no step's timer accounts for, and a
  # boundary nobody measured is a boundary nobody can argue about. The parts are
  # in the order they happened, microseconds, and the total is their sum — the
  # loop's own work between the callbacks is the only thing it leaves out.
  defp boundary_line(parts) do
    total = parts |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    "the boundary took #{milliseconds(total)} ms: " <>
      Enum.map_join(parts, ", ", fn {part, micros} -> "#{part} #{milliseconds(micros)} ms" end)
  end

  defp milliseconds(micros), do: Float.round(micros / 1000, 1)

  defp broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(ExTbpMonty.PubSub, topic(run_id), {:studio, run_id, event})
  end

  # A run has one owner: this worker, until it stops working on it. Registering
  # is how it proves it is alive (see `held?/1` and `Monty.Studio.Jobs.Reaper`).
  defp register(run_id) do
    case Registry.register(Monty.Runtime.Registry, key(run_id), :starting) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp unregister(run_id) do
    Registry.unregister(Monty.Runtime.Registry, key(run_id))
    # A run that has closed has no steps left to ask, and a run of the same id
    # started later is not this one's to stop.
    Stops.clear(run_id)
  end

  defp key(run_id), do: {:studio_run, run_id}
end
