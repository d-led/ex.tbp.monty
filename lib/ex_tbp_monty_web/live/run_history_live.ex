defmodule ExTbpMontyWeb.RunHistoryLive do
  @moduledoc """
  What has run, and what it left behind.

  The index answers "what did I run, and how did it end"; the detail answers
  "with what, and what happened step by step". Both read from
  `Monty.Studio.RunHistory`, so closing a page does not close the record.

  Deleting asks first. A run's record is the only copy of its config snapshot,
  its inputs and its log, and while the artifacts it produced stay on disk, a
  run nobody meant to forget is worth two clicks to lose.
  """

  use ExTbpMontyWeb, :live_view

  alias ExTbpMontyWeb.RunHistoryLive.Selection

  alias Monty.Studio.{
    Artifacts,
    Duration,
    Failure,
    Jobs,
    Json,
    Panel,
    Replay,
    RunHistory,
    RunLog,
    RunStream,
    Setup
  }

  alias Monty.Studio.Jobs.Reaper
  alias Monty.Studio.Replay.Chart

  # The states a run can be in, in the order the filter pills read them.
  @states ~w(running finished stopped failed)

  # Not a column of the record: the chart of every object's evidence at once,
  # which the picker offers when the run built graphs.
  @objects "objects"

  # The same chart from one module's beliefs alone, named `<prefix><module id>`:
  # five modules of one heterarchy are five answers, and the chart above them is
  # the strongest of the five.
  @module_chart "module:"

  @selection_events Selection.events()

  # The replay panel's controls, grouped the same way and for the same reason.
  @replay_events ~w(replay_seek replay_step replay_play replay_pause replay_zoom replay_brush replay_series replay_follow replay_expand replay_collapse)

  # How often a page showing a run asks the record what the run is doing. The
  # worker broadcasts every step, so this is the answer to silence: a message
  # that arrived while the socket was reconnecting, or a worker that died
  # between two steps and will never send another.
  @show_poll_ms 2_000

  # How long the page waits for a run to stop talking before it reads the record.
  # A step is published as several messages, and reading the record once per
  # message meant the page spent longer rendering than the run spent stepping.
  @refresh_after_ms 250

  # The two keys that answer "why did this stop", shown in the failure panel and
  # kept out of the table of everything else.
  @said_above ["reason", "technical"]

  # A step's number restarts in every episode, so it alone does not name a line:
  # the page appends as a run grows, and a stream with two lines of one id is not
  # a page. A run recorded before a step said which episode it was in is one
  # episode.
  defp log_id(entry), do: "log-#{Map.get(entry, "episode") || 0}-#{entry["step"]}"

  # The DOM is not the transcript. A run that stepped 24 329 times sent every
  # line it ever wrote on every mount — 24 329 list items, each with a clock the
  # browser has to localise — and the page answered in seventeen seconds, which
  # is a page the client gives up on and reconnects to, and the reconnect pays
  # it again. The count beside the panel says how long the run is; the tail is
  # what a reader opens a finished run to see; the file has the rest.
  @log_tail 300

  @impl true
  def mount(_params, _session, socket) do
    # The list is a stream fed by the record's topic, not by re-reading: a run
    # appears the moment it is written — queued, before a worker picks it up —
    # and the row it settles into is the row the database wrote.
    if connected?(socket), do: RunHistory.subscribe()

    {:ok,
     socket
     |> assign(
       confirming: nil,
       confirming_bulk: nil,
       selected: MapSet.new(),
       deleting: nil,
       expanded: false,
       log_tail: @log_tail,
       trimmed_log?: false
     )
     |> stream_configure(:log, dom_id: &log_id/1)
     |> stream_configure(:runs, dom_id: &"run-#{&1.id}")
     |> stream(:runs, [])
     |> stream(:log, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # A `running` record whose process is gone is not a run in flight, and a page
    # that showed it as one would be wrong twice — about the run and about
    # whether a new one can start. Settling those is asked for *beside* the page
    # rather than before it: the check reads every open run and asks Oban about
    # each, and a page that waits for it shows nothing until it is done, which is
    # exactly the visit after a restart, when a reader is waiting.
    if connected?(socket), do: start_reap()

    socket = assign(socket, :params, params)

    case socket.assigns.live_action do
      :index -> {:noreply, load_runs(socket, params)}
      :show -> assign_run(params, socket)
    end
  end

  # Asked for here and answered in `handle_info(:reap, ...)`: the check reads
  # every open run and asks Oban about each, so it belongs after this render and
  # before anything the reader can do — not in front of the first paint.
  defp start_reap, do: send(self(), :reap)

  # The filter is the address, so a narrowed list can be sent to a colleague and
  # the back button works.
  defp load_runs(socket, params) do
    state = state_of(params)
    text = params["q"] || ""
    page = page_of(params)
    found = RunHistory.search(state: state, text: text, page: page)

    # A page past the end — the last row of the last page was just deleted — is
    # answered with the last page there is, not with an empty one.
    found =
      if page > found.pages,
        do: RunHistory.search(state: state, text: text, page: found.pages),
        else: found

    counts = RunHistory.counts()

    socket
    |> assign(
      state: state,
      states: @states,
      text: text,
      page: found.page,
      pages: found.pages,
      per_page: found.per_page,
      total: found.total,
      counts: counts,
      # What the purge button would remove: every run that is done, in every
      # filter — the count is about the machine, not about the list on screen.
      done: Map.get(counts, "finished", 0) + Map.get(counts, "stopped", 0),
      page_ids: Enum.map(found.runs, & &1.id),
      # The rows are a stream, and a stream only renders what it is sent: the
      # tick inside a row is drawn from the selection, so a selection change has
      # to re-send the rows or the tick never moves. Hence the runs themselves,
      # not just their ids.
      page_runs: found.runs,
      queue: where_each_run_is(found.runs)
    )
    |> stream(:runs, found.runs, reset: true)
  end

  defp state_of(%{"state" => state}) when state in @states, do: state
  defp state_of(_params), do: "all"

  defp selection(event, params, socket) do
    case Selection.handle(event, params, socket.assigns) do
      {:assign, assigns} -> socket |> assign(assigns) |> redraw_rows()
      {:delete, scope} -> delete_every(socket, scope)
    end
  end

  defp redraw_rows(socket) do
    case socket.assigns[:page_runs] do
      nil -> socket
      runs -> stream(socket, :runs, runs, reset: true)
    end
  end

  # Deleting happens inside the filter the person is looking at, so the list stays
  # the list they were reading — all of a narrowed list, not all of everything.
  #
  # The rows go in a task, not in the event handler: a filter over a year of runs
  # is thousands of rows and tens of megabytes of pictures each, and a page that
  # did it inline froze until the last one was gone, which is the same as saying
  # nothing. The task reports every chunk, so the page can say how far it got.
  defp delete_every(socket, scope) do
    ids =
      case scope do
        {:ids, ids} ->
          ids

        {:matching, filter} ->
          RunHistory.ids_matching(filter)

        :done ->
          RunHistory.ids_matching(state: "finished") ++ RunHistory.ids_matching(state: "stopped")
      end

    page = self()

    socket
    |> assign(confirming_bulk: nil, selected: MapSet.new())
    |> assign(deleting: %{deleted: 0, total: length(ids)})
    |> start_async(:delete, fn ->
      RunHistory.delete_ids(ids, on_progress: &send(page, {:delete_progress, &1}))
    end)
  end

  defp here_is_where_we_are(socket) do
    %{"state" => socket.assigns.state, "q" => socket.assigns.text, "page" => socket.assigns.page}
  end

  defp page_of(%{"page" => page}) do
    case Integer.parse(to_string(page)) do
      {number, ""} -> max(number, 1)
      _not_a_number -> 1
    end
  end

  defp page_of(_params), do: 1

  # The run in the queue that is executing it, keyed by run id — the page reads it
  # only to know whether a run is queued or going, and to have something to stop.
  # A run has at most one unfinished job, and the latest one is the interesting one.
  defp where_each_run_is(runs), do: Jobs.by_run(Enum.map(runs, & &1.id))

  # What a run says about itself and does not change while it runs: the files it
  # wrote, and where it is in the queue.
  #
  # Read by the poll, and not by a step: a step changes what the run said, and
  # neither of these — the job is the same job from the first step to the last,
  # and a run writes its summary and statistics when it stops. Re-reading them
  # per step was a queue query and a directory listing four times a second, which
  # is the sort of per-step cost this page exists without.
  defp put_run(socket, run) do
    assign(socket,
      run: run,
      files: Artifacts.files(run.id),
      queue: where_each_run_is([run])
    )
  end

  # Read once, when the run is opened: a record's config and seed are written
  # when it starts and never change, and reading them back costs a setup.
  defp put_configuration(socket, run), do: assign(socket, configuration: configuration(run))

  defp assign_run(%{"id" => id}, socket) do
    case read_run(socket, id) do
      nil ->
        {:noreply,
         assign(socket, run: nil, moment: nil, configuration: [])
         |> put_flash(:error, "That run is gone.")}

      run ->
        run = with_steps(run)
        socket = for_run(socket, run)

        {:noreply,
         socket
         |> put_run(run)
         |> put_configuration(run)
         |> follow(run)
         |> stream(:log, log_tail(run.log), reset: true)
         |> assign(
           logged: length(run.log),
           dropped: max(length(run.log) - @log_tail, 0),
           trimmed_log?: length(run.log) > @log_tail
         )
         |> assign_replay(run, Replay.last_step(run))}
    end
  end

  defp log_tail(log), do: Enum.take(log, -@log_tail)

  # When the run began, as the instant `LocalTime` reads: the page says how long
  # it has been going beside the plot, and the browser is the only clock that
  # knows how long ago that was.
  defp started_at(%{inserted_at: %DateTime{} = at}), do: DateTime.to_iso8601(at)
  defp started_at(_run), do: nil

  # What the reader chose to look at belongs to the run they chose it for: a
  # series, a window and a step are answers about one run. Carrying them to the
  # next run opened in the same tab meant every run after the first was drawn the
  # way the previous one had been left — one line, no legend, and nothing on the
  # page saying why — because choosing a run is a `patch`, which keeps this
  # process, and its assigns, alive.
  defp for_run(socket, %{id: id}) do
    case socket.assigns[:run] do
      %{id: ^id} ->
        socket

      _another_run ->
        assign(socket,
          series_id: nil,
          series_chosen: false,
          window: nil,
          step: nil,
          playing: false
        )
    end
  end

  # A run that is still stepping has its steps here, in memory, and its row is
  # written at an episode boundary rather than at every step: the stream is the
  # newer of the two, and the only one that has the step being taken. Once the
  # run settles its row has everything and the stream has been dropped, so which
  # of the two answered is not something a caller has to know.
  defp with_steps(%RunHistory.Run{} = run) do
    case steps_after(run) do
      {:grown, grown} -> grown
      _nothing_newer -> run
    end
  end

  # A step is published on the run's topic, which this page already listens to,
  # and it is in memory here: reading the row again for it would decode an
  # episode's log to learn what this process was just told. So a step adds what
  # the stream has that the page does not, and the row is read when this node
  # has no stream of the run at all — a run another node steps, or one whose
  # steps were only ever written down — and when the run ends.
  defp take_steps(%{assigns: %{live_action: :show, run: %RunHistory.Run{id: id} = run}} = socket) do
    case steps_after(run) do
      :no_stream ->
        refresh_run(socket, id)

      :nothing_newer ->
        socket

      {:grown, grown} ->
        socket |> assign(run: grown) |> append_log(grown) |> assign_replay(grown, :follow)
    end
  end

  defp take_steps(socket), do: socket

  # The steps the page does not have yet. The stream numbers a run's steps from
  # its first one, so a page showing a thousand of them asks for the
  # thousand-and-first rather than for a copy of the thousand. Nothing newer than
  # what the page holds is either a stream that stops where the page does, or no
  # stream at all — and only the second means the row may hold steps this page
  # does not, which is why the two are answered differently.
  defp steps_after(%RunHistory.Run{id: id} = run) do
    case RunStream.count(id) do
      0 ->
        :no_stream

      held ->
        if length(run.log) >= held and length(run.timeline) >= held,
          do: :nothing_newer,
          else: {:grown, grown(run)}
    end
  end

  # The log and the moments are topped up separately, because they stop at
  # different places: `head/1` is asked for everything a page reads between steps
  # except the pictures, so a page that has just read a row has its steps and
  # none of their moments, and asks for those from the beginning — once, and then
  # never again while the run steps.
  #
  # The counts and the timestamp are taken from the steps themselves, not left as
  # the row's: a header reading `steps_done` off a row written an episode ago
  # would say "0 steps · nothing recorded for a minute" about a run that is
  # stepping, which is the page lying about the one thing it is for.
  defp grown(%RunHistory.Run{} = run) do
    {fresh_log, _moments} = RunStream.steps_from(run.id, length(run.log) - 1)
    {_steps, fresh_moments} = RunStream.steps_from(run.id, length(run.timeline) - 1)
    log = run.log ++ fresh_log

    %{
      run
      | log: log,
        timeline: run.timeline ++ fresh_moments,
        steps_done: length(log),
        episodes_done: RunHistory.episodes_in(log),
        updated_at: newest(fresh_log) || run.updated_at
    }
  end

  # When the last step was taken: the entry's own clock, which is the instant a
  # reader is shown.
  defp newest([]), do: nil

  defp newest(log) do
    with %{"at" => iso} when is_binary(iso) <- List.last(log),
         {:ok, at, _offset} <- DateTime.from_iso8601(iso) do
      at
    else
      _no_clock -> nil
    end
  end

  # A run that is still going is watched, not photographed: the worker
  # broadcasts each step, so the page reads the record again and the steps, the
  # status and the progress line move while it is open. A finished run is read
  # once and stays still.
  defp follow(socket, run) do
    following = socket.assigns[:followed]

    cond do
      not connected?(socket) or not in_flight?(run, socket.assigns.queue) ->
        socket

      following == run.id ->
        socket

      true ->
        # Navigating from one run to another leaves the first topic behind: a
        # late step from a run this page is not showing would refresh it with
        # the wrong record.
        if following, do: Phoenix.PubSub.unsubscribe(ExTbpMonty.PubSub, Jobs.Run.topic(following))

        Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(run.id))

        assign(socket, followed: run.id) |> schedule_show_poll()
    end
  end

  defp refresh_run(socket, id) do
    case read_run(socket, id) do
      nil ->
        assign(socket, run: nil)

      run ->
        run = with_steps(run)

        socket
        |> put_run(run)
        |> append_log(run)
        |> assign_replay(run, :follow)
    end
  end

  # What a page reads between steps. A run this node is stepping has its steps in
  # memory, and the copy of them that carries an episode and what a module
  # believed is the stream's; what the row adds is how the run is doing. Reading
  # the transcript twice a second to learn that is the page keeping the run's
  # whole log in flight while the run is trying to step, so the row is asked for
  # the counters and the page keeps the steps it has.
  #
  # A run with no stream here — one that has settled, or one another node steps —
  # is read whole from its row, which is then the only account of it.
  defp read_run(%{assigns: %{run: %RunHistory.Run{id: id} = shown}}, id) do
    if streamed?(id) do
      case RunHistory.progress(id) do
        nil -> nil
        fresh -> keep_steps(fresh, shown)
      end
    else
      RunHistory.head(id)
    end
  end

  # A run opened for the first time: the row is read whole because the fields a
  # page shows once — the configuration, the seed, when it started — are in it,
  # and the steps are not taken from it when the stream has them, because the
  # stream's copy is the one that carries an episode and a module's beliefs.
  defp read_run(_socket, id) do
    case RunHistory.head(id) do
      nil -> nil
      row -> if streamed?(id), do: %{row | log: [], timeline: []}, else: row
    end
  end

  # The steps a page shows are the ones it was handed, and a poll is not a reason
  # to build them again: the stream is where they came from, the row is the same
  # run written down. The three fields a counters read does not carry — the
  # configuration, the inputs and the seed — are kept for the same reason: they
  # are written when the run starts and never change, and a page that read them
  # again would read `nil` and quietly print nothing where they were.
  defp keep_steps(%RunHistory.Run{} = fresh, %RunHistory.Run{} = shown) do
    %{
      fresh
      | log: shown.log,
        timeline: shown.timeline,
        config: shown.config,
        inputs: shown.inputs,
        seed: shown.seed
    }
  end

  defp streamed?(id), do: RunStream.count(id) > 0

  # The log grows a step at a time, and the page sends the steps that are new
  # rather than the run's whole scrollback again: a refresh used to re-render and
  # re-send every line of a thousand-step run, twice a second, while the reader
  # was scrolling through them.
  defp append_log(socket, run) do
    shown = socket.assigns[:logged] || 0
    fresh = Enum.drop(run.log, shown)
    total = shown + length(fresh)

    socket
    |> assign(logged: total, trimmed_log?: total > @log_tail)
    |> stream(:log, fresh)
    |> drop_from_log(run, total)
  end

  # A window that only ever grows is the transcript again, reached a line at a
  # time instead of in one mount. Watching a run therefore drops the lines the
  # window has moved past, as the new ones arrive; only the lines that have just
  # left are deleted, so following a long run stays one delete a step rather
  # than one per line already gone.
  defp drop_from_log(socket, run, total) do
    dropped = socket.assigns[:dropped] || 0
    behind = max(total - @log_tail, 0)

    if behind > dropped do
      socket = assign(socket, dropped: behind)

      run.log
      |> Enum.slice(dropped, behind - dropped)
      |> Enum.reduce(socket, &stream_delete(&2, :log, &1))
    else
      socket
    end
  end

  # The replay starts where the run ended: a person opening a finished run wants
  # to see what it came to, and rewinding is one drag away.
  defp assign_replay(socket, run, step) do
    step = step_for(socket, run, step)
    catalog = catalog(socket, run)
    series = charts_of(catalog)

    # A reader who has not chosen a chart gets the one a run is judged by: every
    # object the modules held, as soon as there is one to draw. A run watched
    # from its first step has no beliefs yet, so the first render can only offer
    # the single "best evidence" line — and keeping that choice meant the
    # per-object chart, the reason the page exists, was never drawn for the rest
    # of the run unless the reader went looking for it in the picker.
    series_id =
      if Map.get(socket.assigns, :series_chosen, false) and socket.assigns[:series_id] do
        socket.assigns.series_id
      else
        default_series(series)
      end

    window = window_for(socket, run)
    moment = run |> Replay.at(step) |> with_pictures(run)
    {chart, chart_key, chart_base} = chart_with(socket, catalog, series_id, window, step)

    socket
    |> assign(
      moment: moment,
      step: step,
      last_step: Replay.last_step(run),
      series: series,
      series_id: series_id,
      window: window,
      # Whether the run kept any picture is a property of the run, asked once: a
      # `false` is an answer too, and `||` on it asked again at every step.
      pictures: Map.get_lazy(socket.assigns, :pictures, fn -> kept_pictures?(run) end),
      best: catalog.best,
      theories: Replay.theories(moment),
      graphs: catalog.objects != [],
      chart: chart,
      # Playback is the play button's, not a redraw's: a tick that redrew the
      # page after switching playback off stopped after a single step.
      playing: Map.get(socket.assigns, :playing, false),
      follow: Map.get(socket.assigns, :follow, true)
    )
    |> assign(
      catalog_key: catalog.key,
      catalog: catalog,
      chart_key: chart_key,
      chart_base: chart_base,
      keeping: Map.get(socket.assigns, :keeping),
      # Read once, when the page opens: it is a setting a person changes, not a
      # value to ask the database for on every tick of a live run.
      refresh_ms: Monty.Studio.Settings.get("run_refresh_ms")
    )
  end

  # The pictures of the step being shown, asked for by itself: a record read
  # without its pictures (`RunHistory.head/1`) has no timeline at all, and one
  # step's observations are the only ones a page can draw.
  #
  # Nothing is asked when the run has a timeline: a moment that came with it was
  # handed over with whatever its sensors kept, and asking again would be a
  # database read per step for a page that is following a run.
  defp with_pictures(moment, run) do
    case moment do
      %{frames: [_ | _]} ->
        moment

      %{position: position, step: step} ->
        if run.timeline == [],
          do: Replay.with_pictures(moment, sensors_at(run, position, step)),
          else: moment

      nil ->
        nil
    end
  end

  defp sensors_at(run, position, step) do
    case RunHistory.sensors_at(run.id, position) do
      sensors when is_map(sensors) and map_size(sensors) > 0 -> sensors
      _nothing_recorded -> Monty.Studio.Artifacts.frames_at(run.id, step)
    end
  end

  # A record that still says "running" is not the same as a run that is: a
  # process killed mid-flight leaves the row open, and a clock beside it would
  # count the minutes since it died as time it has been going. `stalled?` is the
  # page's own answer to "is anything still stepping this", and the reaper is
  # what closes the record.
  defp running?(%{status: "running"} = run), do: not RunHistory.stalled?(run)
  defp running?(_not_running), do: false

  defp kept_pictures?(run), do: run.id |> RunHistory.sensors_at(0) |> Replay.kept_pictures?()

  # A run that is still stepping moves on without the page. Reading the record
  # again answers the step the page already held, so a replay that kept it was a
  # picture of the moment the page was opened however long the run went on: the
  # graph stopped following the evidence while the run kept producing it.
  #
  # Only a refresh asks to follow — it passes `:follow` rather than a step. A
  # step the reader chose is theirs, and no refresh takes it away; the playhead
  # follows the end of the run only while it was already at that end.
  defp step_for(socket, run, :follow) do
    last = Replay.last_step(run)

    case {Map.get(socket.assigns, :follow, true), socket.assigns[:step],
          socket.assigns[:last_step]} do
      # Not following: wherever the reader left it is the step to show.
      {false, step, _observed} -> step || last
      {true, nil, _was} -> last
      {true, was, was} -> last || was
      {true, was, _observed} -> was
    end
  end

  defp step_for(_socket, _run, step), do: step

  # The window grows with the run while it is the whole run — a chart of a run
  # that ended at step 13 cannot say anything about step 300. A stretch the
  # reader zoomed into is theirs until they ask for the whole run again.
  defp window_for(socket, run) do
    if Map.get(socket.assigns, :window_follows?, true),
      do: whole_run(run),
      else: socket.assigns[:window] || whole_run(run)
  end

  defp whole_run(run) do
    {Replay.first_step(run) || 0, Replay.last_step(run) || 0}
  end

  # The chart opens on the lines an episode is judged by — every object the
  # modules still held, whose climbing away from the rest *is* the recognition —
  # and falls back to the single evidence curve, then to whatever there is.
  defp default_series(series) do
    Enum.find_value(series, first_id(series), fn
      %{id: @objects} -> @objects
      %{id: "evidence"} -> "evidence"
      _other -> nil
    end)
  end

  defp first_id([first | _rest]), do: first.id
  defp first_id([]), do: nil

  # Every line the replay can draw, worked out once per version of the record.
  # The answer to "which objects did this run still hold, and how strongly" is
  # the same for the same record, and rebuilding it on every drag of the slider
  # was most of what a drag cost.
  defp catalog(socket, run) do
    key = {run.id, length(run.log), length(run.timeline)}

    case socket.assigns[:catalog_key] do
      ^key ->
        socket.assigns.catalog

      _other ->
        %{
          key: key,
          objects: Replay.objects(run),
          module_objects: Map.new(Replay.modules(run), &{&1, Replay.objects(run, &1)}),
          series: Replay.series(run),
          best: Replay.best_evidence(run)
        }
    end
  end

  # The per-object chart is offered first when a run built graphs: a single
  # maximum hides what the episode was actually about, which objects were still
  # in the running and when one of them won.
  #
  # Then one chart a module, for the same reason one more step out. A heterarchy
  # is several opinions about the same objects and the first chart is the
  # strongest of them, so four modules agreeing less than a fifth is invisible
  # there — and so is a module that recognised the object while the others timed
  # out, which is what a run whose ensemble matched and whose modules did not
  # looks like from the outside.
  defp charts_of(%{objects: [], series: series}), do: series

  defp charts_of(%{objects: objects, module_objects: module_objects, series: series}) do
    every_object = %{
      id: @objects,
      label: "every object (#{length(objects)})",
      title: "Evidence for every object — strongest module",
      unit: "",
      axis: "evidence",
      points: []
    }

    per_module =
      for {module_id, lines} <- Enum.sort(module_objects), lines != [] do
        %{
          id: @module_chart <> module_id,
          label: "objects · #{module_id}",
          title: "Evidence for every object — as #{module_id} held it",
          unit: "",
          axis: "evidence",
          points: []
        }
      end

    [every_object | per_module] ++ series
  end

  # The chart, and what it was drawn from: the lines, the axis and the samples a
  # hover reads are a function of the series and the window, so they are drawn
  # once and kept. Dragging the slider then moves one dashed line instead of
  # rebuilding every point of every line, which is what a drag is supposed to be.
  defp chart_with(socket, catalog, series_id, window, step) do
    key = {catalog.key, series_id, window}

    base =
      case socket.assigns[:chart_key] do
        ^key -> socket.assigns.chart_base
        _other -> Chart.many(chart_lines(catalog, series_id), window: window)
      end

    {Chart.with_playhead(base, step), key, base}
  end

  defp chart_lines(%{objects: objects}, @objects), do: objects

  defp chart_lines(%{module_objects: module_objects}, @module_chart <> module_id),
    do: Map.get(module_objects, module_id, [])

  # The best-evidence line is drawn as one stretch per object: the object holding
  # the strongest evidence changes with the episode, and a single-coloured line
  # could not say whose it was at any point on it. Each stretch carries the
  # object's name, so the colour is the same one its episode band has, the legend
  # can list the objects it passes through, and a hover names the one under the
  # pointer.
  defp chart_lines(%{series: series}, "evidence") do
    evidence = Enum.filter(series, &(&1.id == "evidence"))

    # A run whose modules kept no graphs has nothing to name: it keeps the one
    # plain line, and the page says why it is flat rather than drawing nothing.
    case Enum.flat_map(evidence, &named_stretches/1) do
      [] -> evidence
      stretches -> stretches
    end
  end

  defp chart_lines(%{series: series}, series_id), do: Enum.filter(series, &(&1.id == series_id))

  defp named_stretches(%{points: points}) do
    points
    |> Enum.chunk_by(&Map.get(&1, :object))
    |> Enum.reject(&is_nil(Map.get(hd(&1), :object)))
    |> Enum.map(fn [first | _] = stretch ->
      %{id: first.object, label: first.object, points: stretch}
    end)
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header class="flex flex-wrap items-end justify-between gap-2">
        <div class="space-y-1">
          <h1 class="text-3xl font-semibold tracking-tight">Runs</h1>
          <p class="text-sm text-base-content/70">
            Every run is recorded when it starts: which experiment, with which config and
            inputs, and how it ended. A run that is waiting or going can be stopped here.
          </p>
        </div>
        <.link navigate={~p"/experiments"} class="btn btn-ghost btn-sm">Experiments</.link>
      </header>

      <div class="flex flex-wrap items-center gap-2">
        <div id="run-filters" class="flex flex-wrap items-center gap-1">
          <.link patch={filter_href("all", @text)} class={pill_class(@state == "all")} id="filter-all">
            all {@counts |> Map.values() |> Enum.sum()}
          </.link>
          <.link
            :for={state <- @states}
            patch={filter_href(state, @text)}
            class={pill_class(@state == state)}
            id={"filter-#{state}"}
          >
            {state} {Map.get(@counts, state, 0)}
          </.link>
        </div>

        <form id="run-search" phx-change="filter" phx-debounce="150" class="ms-auto">
          <input
            type="search"
            name="q"
            value={@text}
            placeholder="experiment name: every word must match"
            class="input input-sm w-full min-w-[18rem] max-w-sm"
            aria-label="Filter the runs by experiment name: every word must match"
          />
        </form>

        <span id="run-count" class="font-mono text-xs text-base-content/60">
          {showing(@page, @per_page, @total)}
        </span>
      </div>

      <%!-- Two ways to delete more than one run: the ones picked, or everything the
      filter shows. Both ask once, because both are the same keystroke away from
      losing a run's only record. --%>
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span :if={MapSet.size(@selected) > 0} id="selected-count" class="text-base-content/60">
          {MapSet.size(@selected)} selected
        </span>
        <button
          :if={MapSet.size(@selected) > 0}
          id="delete-selected"
          phx-click="ask_delete_selected"
          disabled={@deleting != nil}
          class="btn btn-ghost btn-xs text-error"
        >
          Delete selected
        </button>
        <button
          :if={MapSet.size(@selected) > 0}
          id="clear-selection"
          phx-click="clear_selection"
          class="btn btn-ghost btn-xs"
        >
          Clear selection
        </button>
        <button
          :if={@total > 0 and not all_picked?(@selected, @page_ids)}
          id="select-all"
          phx-click="toggle_all"
          class="btn btn-ghost btn-xs"
        >
          Select all {length(@page_ids)} shown
        </button>
        <button
          :if={@total > 0}
          id="delete-matching"
          phx-click="ask_delete_matching"
          disabled={@deleting != nil}
          class="btn btn-ghost btn-xs text-error ms-auto"
          title="Every run the filter matches, not only this page"
        >
          {matching_delete_label(@state, @text, @total)}
        </button>
        <%!-- Clearing a machine of finished work: the filter is not the subject,
        so this one ignores it — it counts every run that is done, whatever the
        pills say. --%>
        <button
          :if={@done > 0}
          id="purge-done"
          phx-click="ask_purge_done"
          disabled={@deleting != nil}
          class="btn btn-ghost btn-xs text-error"
          title="Every finished and stopped run, whatever this page shows"
        >
          Purge {@done} done
        </button>
      </div>

      <p :if={@deleting} id="deleting" class="flex items-center gap-2 text-xs text-base-content/60">
        <span class="loading loading-spinner loading-xs"></span>
        Deleting {@deleting.deleted} of {@deleting.total} runs…
      </p>

      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table id="runs-table" phx-hook={ExTbpMontyWeb.LocalTime.hook_name()} class="table table-sm">
          <thead>
            <tr class="text-xs text-base-content/60">
              <th class="w-6">
                <%!-- daisyUI's pastel primary draws a pale tick on a pale box,
                which is invisible; the state is drawn here instead: filled and
                checked when every run on the page is picked. --%>
                <button
                  id="pick-all"
                  phx-click="toggle_all"
                  class="grid size-4 place-items-center rounded border border-base-300"
                  aria-pressed={to_string(all_picked?(@selected, @page_ids))}
                  aria-label="Pick every run on this page"
                  title="Pick every run on this page"
                >
                  <.icon
                    name="hero-check-mini"
                    class={[
                      "size-3",
                      if(all_picked?(@selected, @page_ids),
                        do: "text-base-content",
                        else: "text-transparent"
                      )
                    ]}
                  />
                </button>
              </th>
              <th class="whitespace-nowrap">started</th>
              <th>experiment</th>
              <th>state</th>
              <th class="text-right whitespace-nowrap">steps</th>
              <th
                class="text-right whitespace-nowrap"
                title="Wall-clock time from the run's first step to its last"
              >
                elapsed
              </th>
              <th class="whitespace-nowrap">ending</th>
              <th class="text-right"></th>
            </tr>
          </thead>
          <tbody id="runs" phx-update="stream">
            <tr id="runs-empty" class="hidden only:table-row">
              <td colspan="8" class="text-sm text-base-content/60">
                No run matches.
                <.link patch={filter_href(@state, "")} class="link link-primary">Clear the filter</.link>
              </td>
            </tr>
            <tr :for={{dom_id, run} <- @streams.runs} id={dom_id}>
              <td class="w-6">
                <button
                  id={"pick-#{run.id}"}
                  phx-click="toggle"
                  phx-value-id={run.id}
                  class="grid size-4 place-items-center rounded border border-base-300"
                  aria-pressed={to_string(MapSet.member?(@selected, run.id))}
                  aria-label={"Pick the run of " <> run.experiment}
                >
                  <.icon
                    name="hero-check-mini"
                    class={[
                      "size-3",
                      if(MapSet.member?(@selected, run.id),
                        do: "text-base-content",
                        else: "text-transparent"
                      )
                    ]}
                  />
                </button>
              </td>
              <td class="font-mono text-xs whitespace-nowrap">
                <ExTbpMontyWeb.LocalTime.local_time at={run.inserted_at} class="tabular-nums" />
              </td>
              <td class="whitespace-nowrap">
                <.link navigate={~p"/runs/#{run.id}"} class="link link-hover font-mono text-sm">
                  {run.experiment}
                </.link>
                <%!-- Which slice of the experiment this row is, and how much of
                it actually ran: the name alone does not say it, and the record's
                episode is where the run started rather than how far it got. --%>
                <span
                  id={"episodes-#{run.id}"}
                  class="ms-1.5 font-mono text-[10px] text-base-content/50"
                >
                  {episodes_label(run)}
                </span>
                <%!-- Which world it stepped: two runs of one experiment are not
                comparable otherwise, and the default is not the only choice. --%>
                <span class="ms-1.5 font-mono text-[10px] text-base-content/40">
                  {ExTbpMontyWeb.StudioComponents.world_label(run)}
                </span>
              </td>
              <td>
                <span class={["badge badge-sm", status_class(run_state(run, @queue[run.id]))]}>
                  {run_state(run, @queue[run.id])}
                </span>
                <%!-- Running and silent is its own story: the badge says what
                the record says, and this says whether to believe it. --%>
                <span
                  :if={RunHistory.stalled?(run)}
                  id={"quiet-#{run.id}"}
                  class="ms-1 font-mono text-[10px] text-warning"
                >
                  quiet {quiet(run)}
                </span>
              </td>
              <td
                id={"steps-#{run.id}"}
                class="text-right font-mono text-xs tabular-nums"
                title={"up to #{run.steps} steps an episode"}
              >
                {RunHistory.steps_run(run)}
              </td>
              <td class="text-right font-mono text-xs whitespace-nowrap">
                {Duration.of_run(run)}
              </td>
              <%!-- What the run concluded, when it concluded something other
              than using up its budget: the step count alone cannot tell a run
              that recognised its object from one that ran out. --%>
              <td
                id={"ending-#{run.id}"}
                class="text-xs whitespace-nowrap text-base-content/70"
              >
                {RunHistory.ending(run)}
              </td>
              <td class="text-right whitespace-nowrap">
                <%!-- Two ways out: a run that is stepping ends at its next step of
                its own accord, one stuck in a step has to be ended. --%>
                <button
                  :if={in_flight?(run, @queue)}
                  id={"stop-#{run.id}"}
                  phx-click="stop"
                  phx-value-id={run.id}
                  class="btn btn-ghost btn-xs text-warning"
                  title="Stop it at its next step"
                >
                  Stop
                </button>
                <button
                  :if={running_now?(run, @queue)}
                  id={"end-#{run.id}"}
                  phx-click="end_now"
                  phx-value-id={run.id}
                  class="btn btn-ghost btn-xs text-error"
                  title="End it now"
                >
                  End now
                </button>
                <%!-- A record nobody needs is deleted; a run in flight is
                stopped or ended. Offering Delete while it runs would be
                offering a button the studio refuses. --%>
                <button
                  :if={not in_flight?(run, @queue)}
                  id={"delete-#{run.id}"}
                  phx-click="ask_delete"
                  phx-value-id={run.id}
                  class="btn btn-ghost btn-xs text-error"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <ExTbpMontyWeb.LocalTime.local_time_hook />
      </div>

      <div class="flex items-center gap-3 text-xs">
        <.link
          :if={@page > 1}
          id="page-previous"
          patch={page_href(@page - 1, @state, @text)}
          class="btn btn-ghost btn-xs"
        >
          ‹ previous
        </.link>
        <span id="page-number" class="text-base-content/60">page {@page} of {@pages}</span>
        <.link
          :if={@page < @pages}
          id="page-next"
          patch={page_href(@page + 1, @state, @text)}
          class="btn btn-ghost btn-xs"
        >
          next ›
        </.link>
      </div>

      <.confirm_bulk :if={@confirming_bulk} confirming={@confirming_bulk} />

      <.confirm_delete :if={@confirming} run={@confirming} />
    </Layouts.app>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header :if={@run} class="space-y-1">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="font-mono text-2xl font-semibold tracking-tight">{@run.experiment}</h1>
          <span class="badge badge-sm" id="run-episode">episode {@run.episode}</span>
          <span
            id="run-status"
            class={["badge badge-sm", status_class(run_state(@run, @queue[@run.id]))]}
          >
            {run_state(@run, @queue[@run.id])}
          </span>
          <span
            :if={in_flight?(@run, @queue)}
            id="run-progress"
            class="badge badge-ghost badge-sm"
          >
            step {steps_into_episode(@run)} / {@run.steps}
          </span>
          <span class="badge badge-ghost badge-sm">{@run.source}</span>

          <%!-- Watching happens here: this page follows the run it shows. The
          experiment page is where a run is started, so that is all this link
          claims to do. --%>
          <div class="ms-auto flex items-center gap-1">
            <.link
              id="open-experiment"
              navigate={~p"/experiments/#{@run.experiment}"}
              class="btn btn-ghost btn-xs"
            >
              Open the experiment
            </.link>

            <%!-- Three different things, three different words: a run that is
            stepping ends at its next step, one stuck inside a step has to be
            ended, and deleting is for records nobody needs any more — which is
            why it is not offered while the run is still going. --%>
            <button
              :if={in_flight?(@run, @queue)}
              id={"stop-#{@run.id}"}
              phx-click="stop"
              phx-value-id={@run.id}
              class="btn btn-outline btn-xs"
              title="Stop it at its next step"
            >
              Stop
            </button>
            <button
              :if={running_now?(@run, @queue)}
              id={"end-#{@run.id}"}
              phx-click="end_now"
              phx-value-id={@run.id}
              class="btn btn-ghost btn-xs text-error"
              title="End it now"
            >
              End now
            </button>
            <button
              :if={not in_flight?(@run, @queue)}
              id={"delete-#{@run.id}"}
              phx-click="ask_delete"
              phx-value-id={@run.id}
              class="btn btn-ghost btn-xs text-error"
            >
              Delete
            </button>
          </div>
        </div>
        <p class="text-xs text-base-content/60">
          started <ExTbpMontyWeb.LocalTime.local_time at={@run.inserted_at} style={:clock} />
          · {RunHistory.steps_run(@run)} steps in {episodes_label(@run)} · {Duration.of_run(@run)}
          <span :if={RunHistory.ending(@run)} id="run-ending">
            · {RunHistory.ending(@run)}
          </span>
          <%!-- "Time is not enough": a stamp says when the last step was, not
          whether another is coming. This says both — the run claims to be
          running and nothing has been recorded for longer than a slow step. --%>
          <span :if={@keeping} id="run-keeping" class="text-info">
            · saving {@keeping} steps to the database
          </span>
          <span
            :if={is_nil(@keeping) and RunHistory.stalled?(@run)}
            id="run-stalled"
            class="text-warning"
          >
            · nothing recorded for {quiet(@run)} — not progressing
          </span>
        </p>
      </header>

      <%!-- A run that did not finish says why — in a sentence, not in a
      stacktrace. The words whatever stopped it used are one fold away, for
      whoever is debugging, and out of the way for everybody else. --%>
      <section
        :if={failure(@run)}
        id="run-failure"
        class="space-y-1 rounded-field border border-error/40 bg-error/10 px-3 py-2"
      >
        <p class="text-sm font-medium">This run did not finish.</p>
        <p id="run-failure-what" class="text-sm">{failure(@run).what}</p>
        <p :if={failure(@run).hint} id="run-failure-hint" class="text-xs text-base-content/70">
          {failure(@run).hint}
        </p>
        <details :if={failure(@run).technical} id="run-failure-technical">
          <summary class="cursor-pointer text-[11px] text-base-content/50 hover:text-base-content">
            Technical details
          </summary>
          <pre class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-[11px] text-base-content/70">{failure(@run).technical}</pre>
        </details>
        <%!-- A run can stop because a file it reads before it steps is not
        here, and the prerequisites page is where each of those files, where it
        belongs and what the last fetch of it did are written down. Offered only
        when the explanation says so: a run whose process was killed has nothing
        to do there. --%>
        <p :if={failure(@run).prerequisites} class="text-xs">
          <.link id="run-failure-prerequisites" navigate={~p"/prerequisites"} class="link">
            What this experiment needs before it can run
          </.link>
        </p>
      </section>

      <section :if={@run == nil} class="text-base-content/70">
        <p>That run is gone.</p>
        <.link navigate={~p"/runs"} class="btn btn-sm btn-outline">All runs</.link>
      </section>

      <section :if={@run} class="grid gap-3 lg:grid-cols-2">
        <div class="space-y-1">
          <h2 class="text-sm font-medium">Inputs</h2>
          <dl
            id="run-inputs"
            class="overflow-hidden rounded-box border border-base-300 bg-base-100 text-xs"
          >
            <div
              :for={{key, value} <- inputs(@run)}
              class="flex gap-2 border-b border-base-300 px-2.5 py-1 last:border-0"
            >
              <dt class="w-32 shrink-0 text-base-content/60">{key}</dt>
              <dd class="font-mono break-all">{value}</dd>
            </div>
          </dl>
        </div>

        <div class="space-y-1">
          <h2 class="text-sm font-medium">Summary</h2>
          <dl class="grid grid-cols-2 gap-1.5 rounded-box border border-base-300 bg-base-100 p-2 text-xs sm:grid-cols-3">
            <div :for={{key, value} <- summary(@run)}>
              <dt class="text-base-content/60">{key}</dt>
              <dd class="font-mono">{value}</dd>
            </div>
          </dl>
        </div>
      </section>

      <section
        :if={@run}
        id="replay-panel"
        class="space-y-1"
        phx-hook=".EscapeReplay"
        phx-window-keydown="replay_collapse"
        phx-key="Escape"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".EscapeReplay">
          // Escape leaves full screen at once, in the browser, and tells the
          // server after. It used to be `phx-window-keydown` on this section,
          // which is a round trip: while a run is stepping that round trip is
          // what made Escape feel like a key that does nothing. What the browser
          // drops here is what the server's next patch removes anyway.
          export default {
            mounted() {
              this.escape = (event) => {
                if (event.key !== "Escape") return

                const panel = this.el.querySelector("#replay-chart-panel")
                if (panel === null || !panel.className.includes("fixed")) return

                panel.className = "space-y-2 pt-1"

                const button = panel.querySelector("#replay-expand")
                if (button !== null) {
                  button.setAttribute("aria-label", "full screen")
                  // The glyph is a heroicon span named by its class: leaving full
                  // screen is the picture expanding again.
                  const glyph = button.querySelector("span")
                  if (glyph !== null) {
                    glyph.classList.replace("hero-arrows-pointing-in", "hero-arrows-pointing-out")
                  }
                }

                this.pushEvent("replay_collapse", {})
              }

              window.addEventListener("keydown", this.escape)
            },

            destroyed() {
              window.removeEventListener("keydown", this.escape)
            }
          }
        </script>
        <ExTbpMontyWeb.StudioComponents.replay
          moment={@moment}
          chart={@chart}
          series={@series}
          series_id={@series_id}
          best={@best}
          theories={@theories}
          graphs={@graphs}
          pictures={@pictures}
          started_at={started_at(@run)}
          running={running?(@run)}
          recorded={length(Replay.steps(@run))}
          playing={@playing}
          follow={@follow}
          expanded={@expanded}
        />
      </section>

      <section :if={@run} class="space-y-1">
        <h2 class="text-sm font-medium">Log</h2>
        <p :if={@trimmed_log?} id="run-log-trimmed" class="text-xs text-base-content/60">
          The last {@log_tail} of {@logged} lines: this page does not carry a
          whole transcript, and the run's own file has every line of it.
        </p>
        <ul
          id="run-log"
          phx-update="stream"
          phx-hook={ExTbpMontyWeb.LocalTime.hook_name()}
          class="max-h-[28rem] overflow-auto rounded-box border border-base-300 bg-base-100 p-2 font-mono text-[11px] leading-5"
        >
          <%!-- What the reader is waiting for is said where the waiting
          happens: a queued or stepping run's steps arrive here, one line per
          step, and the page keeps itself up to date while it is open. --%>
          <li id="run-log-empty" class="hidden only:block text-base-content/50">
            <%= if in_flight?(@run, @queue) do %>
              <span id="run-waiting">
                Waiting for the first step — the steps appear here as the run goes.
              </span>
            <% else %>
              no steps recorded
            <% end %>
          </li>
          <%!-- The clock is a `<time>` carrying the instant, not a string: a
          step's time means the reader's clock, and only the browser knows that
          zone. `RunLog.line/1` builds the same words with the server's clock,
          which is right for the log file on disk and wrong for a page. --%>
          <li :for={{dom_id, entry} <- @streams.log} id={dom_id}>
            <% at = RunLog.at(entry) %>
            <ExTbpMontyWeb.LocalTime.local_time
              :if={at}
              at={at}
              style={:clock}
              class="me-1.5 text-base-content/40 tabular-nums"
            />{RunLog.text(entry)}
          </li>
        </ul>
      </section>

      <section :if={@run} class="space-y-1">
        <h2 class="text-sm font-medium">Artefacts</h2>
        <p :if={@files == []} id="run-files-empty" class="text-xs text-base-content/60">
          <%= if in_flight?(@run, @queue) do %>
            The files appear here when the run finishes: summary, statistics and the
            sensors' pictures.
          <% else %>
            This run wrote no files. Its log says which classes its config asked for and
            which of them this port does not have.
          <% end %>
        </p>
        <ul
          :if={@files != []}
          id="run-files"
          class="overflow-hidden rounded-box border border-base-300 bg-base-100 text-xs"
        >
          <li
            :for={file <- @files}
            id={"run-file-" <> String.replace(file.name, ".", "-")}
            class="flex items-center gap-3 border-b border-base-300 px-2.5 py-1 last:border-0"
          >
            <.link
              href={~p"/runs/#{@run.id}/files/#{file.name}"}
              class="link link-hover font-mono text-sm text-base-content"
            >
              {file.name}
            </.link>
            <span class="ms-auto font-mono text-[11px] text-base-content/60">{bytes(file.bytes)}</span>
          </li>
        </ul>
      </section>

      <section :if={@run} class="space-y-1">
        <h2 class="text-sm font-medium">Configuration</h2>
        <%!-- The configuration this run was started with, in the words the
        experiment page promised it in: read back from the record rather than
        from whatever the experiment says today, so a run of a config that has
        since changed still reads as the run it was. --%>
        <dl
          id="run-configuration"
          class="grid gap-2 rounded-box border border-base-300 bg-base-100 p-2 text-xs sm:grid-cols-2 lg:grid-cols-3"
        >
          <div :for={{label, value} <- @configuration}>
            <dt class="text-base-content/60">{label}</dt>
            <dd class="font-mono break-words">{value}</dd>
          </div>
        </dl>
        <p :if={@configuration == []} class="text-xs text-base-content/60">
          This record kept no config, so there is nothing to read back.
        </p>
      </section>

      <%!-- The snapshot is the run's whole config, and a person reads the facts
      above it far more often than the file they came from. A `details` is the
      closed-by-default version of that: the browser remembers nothing for it,
      the page patches it without disturbing what is open, and it is the same
      control with or without JavaScript. --%>
      <details :if={@run} id="run-snapshot" class="space-y-1">
        <summary class="cursor-pointer text-sm font-medium">Config snapshot</summary>
        <pre
          id="run-config"
          class="mt-1 max-h-80 overflow-auto rounded-box border border-base-300 bg-base-100 p-3 font-mono text-[11px]"
        ><code>{Json.highlight(@run.config)}</code></pre>
      </details>

      <.confirm_delete :if={@confirming} run={@confirming} />
    </Layouts.app>
    """
  end

  # Typing in the filter is a navigation: the address carries it, so a narrowed
  # list is shareable and the back button undoes it.
  def handle_event("filter", %{"q" => text}, socket) do
    {:noreply, push_patch(socket, to: filter_href(socket.assigns.state, text))}
  end

  # Picking rows and deleting them is one small piece of state with rules of its
  # own (see Selection), so every one of its events arrives here and leaves as an
  # assignment. The page keeps no branches of its own about it.
  def handle_event(event, params, socket) when event in @selection_events do
    {:noreply, selection(event, params, socket)}
  end

  def handle_event("ask_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: RunHistory.head(id))}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %{} = run <- RunHistory.head(id),
         {:ok, _deleted} <- RunHistory.delete(run) do
      delete_run(socket, run)
    else
      _already_gone -> {:noreply, assign(socket, confirming: nil)}
    end
  end

  # Stopping a run that is waiting cancels it outright; one that is stepping ends
  # at its next step and writes its own summary. Ending is for a run stuck inside
  # a step, which nothing but ending the process will release.
  #
  # The job is looked up again before anything is concluded: the row this page
  # drew can be older than the queue (a job retried, replaced, or picked up
  # after the page looked), and a button that says "already finished" about a
  # run that is stepping is worse than a slow one.
  def handle_event("stop", %{"id" => run_id}, socket) do
    with %{id: job_id} <- job_for(socket, run_id),
         {:ok, ended} <- Jobs.cancel(job_id) do
      {:noreply, socket |> put_flash(:info, stopped_message(ended)) |> after_queue_change()}
    else
      _nothing_to_stop ->
        {:noreply,
         socket
         |> put_flash(:error, "That run had already finished — nothing was stopped.")
         |> after_queue_change()}
    end
  end

  def handle_event("end_now", %{"id" => run_id}, socket) do
    with %{id: job_id} <- job_for(socket, run_id),
         {:ok, _settled} <- Jobs.halt(job_id) do
      {:noreply,
       socket |> put_flash(:info, "Ended: the run stopped where it was.") |> after_queue_change()}
    else
      _not_running ->
        {:noreply,
         socket
         |> put_flash(:error, "That run is not running — there is nothing to end.")
         |> after_queue_change()}
    end
  end

  # -- the replay ------------------------------------------------------------

  @impl true
  # The replay panel's controls are one concern — move through the run, look at a
  # window of it, pick a line — so they arrive here and leave as one answer.
  def handle_event(event, params, socket) when event in @replay_events do
    {:noreply, replay(event, params, socket)}
  end

  defp replay("replay_seek", %{"step" => step}, %{assigns: %{run: run}} = socket),
    do: socket |> assign(follow: false) |> replay_to(run, parse_step(step))

  defp replay("replay_step", %{"delta" => delta}, %{assigns: %{run: run}} = socket),
    do: socket |> assign(follow: false) |> replay_to(run, socket.assigns.step + parse_step(delta))

  defp replay("replay_play", _params, %{assigns: %{run: run}} = socket) do
    socket =
      if Replay.last_step(run) == socket.assigns.step do
        # Playing a run that is already at its end starts again from the top,
        # which is what a person who pressed play wanted.
        replay_to(socket, run, Replay.first_step(run))
      else
        socket
      end

    socket |> assign(playing: true) |> schedule_replay()
  end

  defp replay("replay_pause", _params, socket), do: assign(socket, playing: false)

  # A chart that fills the window is how a shape is read: the run page draws it
  # in a column beside the frames, and a chart in a column is a thumbnail of the
  # evidence rather than a reading of it.
  defp replay("replay_expand", _params, socket),
    do: assign(socket, expanded: not Map.get(socket.assigns, :expanded, false))

  # Escape is the control a full-screen anything answers to.
  defp replay("replay_collapse", _params, socket), do: assign(socket, expanded: false)

  # Ticking "follow latest steps" is a request for the newest step, which is the
  # one thing the page should not wait for the next refresh to hear about. The
  # tick's own value travels with the click, so a second activation of the same
  # click cannot put the box back where it was.
  defp replay("replay_follow", params, %{assigns: %{run: run}} = socket) do
    if wanted_follow(params, socket) do
      socket |> assign(follow: true) |> replay_to(run, Replay.last_step(run))
    else
      assign(socket, follow: false)
    end
  end

  # The shared chart hook asks for the whole run with `how`; this page's own
  # control asks with `zoom`. Both are the same request.
  defp replay("replay_zoom", %{"zoom" => zoom}, socket),
    do: replay("replay_zoom", %{"how" => zoom_of(zoom)}, socket)

  defp replay("replay_zoom", %{"how" => how}, %{assigns: %{run: run}} = socket) do
    replay_window(socket, Replay.zoom(run, socket.assigns.window, socket.assigns.step, how))
  end

  # A drag across the chart chose the range it drew: that is the window now,
  # kept inside the run like any other zoom.
  defp replay("replay_brush", %{"from" => from, "to" => to}, %{assigns: %{run: run}} = socket) do
    replay_window(socket, Replay.window(run, {parse_step(from), parse_step(to)}))
  end

  defp replay("replay_series", %{"series" => id}, socket) do
    socket
    |> assign(series_id: id, series_chosen: true)
    |> replay_window(socket.assigns.window)
  end

  @impl true
  def handle_info(:replay_tick, socket), do: replay_tick(socket)

  # The staleness check this page asked for when it loaded.
  def handle_info(:reap, socket), do: {:noreply, after_reap(socket, Reaper.sweep())}

  # The run said something: a step, the end of it, or a failure. The worker
  # publishes on the run's topic as `{:studio, run_id, event}`, and reading the
  # record again is what keeps one source of truth — the worker writes it, the
  # page shows it. This page subscribes to one topic, the run it shows, so every
  # message on it is that run's.
  #
  # A step is several messages, and reading the record is not free: a page that
  # read it once per message spent longer rebuilding itself than the run spent
  # stepping, so a burst of them became a queue of rebuilds that fell further
  # behind with every step. The first message of a burst is answered at once and
  # the rest wait for `@refresh_after_ms`, which coalesces them into one read.
  # The end of a run is never news to wait on: a page that says "running" for a
  # quarter of a second after the run has stopped is a page lying, however
  # briefly.
  def handle_info({:studio, _run_id, {:keeping, steps}}, socket),
    do: {:noreply, assign(socket, keeping: steps)}

  def handle_info({:studio, _run_id, :kept}, socket),
    do: {:noreply, assign(socket, keeping: nil)}

  def handle_info({:studio, _run_id, ending}, socket)
      when is_tuple(ending) and elem(ending, 0) in [:finished, :failed],
      do: refresh_now(socket)

  def handle_info({:studio, _run_id, _event}, socket) do
    if answered?(socket),
      do: {:noreply, refresh_later(socket)},
      else: {:noreply, take_steps(socket)}
  end

  def handle_info(:refresh_due, socket) do
    {:noreply, socket |> assign(refresh_due: false) |> take_steps()}
  end

  # A page that shows a run keeps asking, even though the worker broadcasts: a
  # message can arrive while the socket is reconnecting, and a worker can die
  # without saying anything at all.
  def handle_info(:show_poll, socket), do: {:noreply, poll_shown_run(socket)}

  # A run was written down, or settled. The index draws the record it was told
  # about; the detail page keeps its own place and only asks for its own run.
  def handle_info({:recorded, run}, socket), do: recorded(socket, run)

  # Zero is the ordinary answer to the staleness check and costs nothing.
  # Anything else means a run this page may be showing has just been settled, so
  # the page is read again: the broadcast the Reaper sends covers the run a page
  # is watching, and this covers the list.
  def handle_info({:settled, run}, socket), do: settled(socket, run)

  # How far a delete has got. A chunk that finishes after the last one has been
  # reported is a message from a delete that is over, and not news.
  def handle_info({:delete_progress, _progress}, %{assigns: %{deleting: nil}} = socket),
    do: {:noreply, socket}

  def handle_info({:delete_progress, progress}, socket),
    do: {:noreply, assign(socket, deleting: progress)}

  # A page can outlive the thing that was talking to it: a message for another
  # page, or one that arrived after the run was closed. It is not news.
  def handle_info(_late_message, socket), do: {:noreply, socket}

  # Zero is the ordinary answer to the staleness check and costs nothing. Anything
  # else means a run this page may be showing has just been settled, so the page
  # is read again: the broadcast the Reaper sends covers the run a page is
  # watching, and this covers the list.
  defp after_reap(socket, closed) when closed > 0 do
    case socket.assigns.live_action do
      :index -> load_runs(socket, Map.get(socket.assigns, :params, %{}))
      :show -> refresh_run(socket, socket.assigns.run.id)
    end
  end

  defp after_reap(socket, _closed), do: socket

  # The delete is over: say how many went, and read the list again — the rows
  # are a stream, and deleting is the one change a stream cannot be told about
  # one row at a time when a filter took them all.
  # What a stale queue row costs: the job a page holds can be one the queue has
  # since replaced. Asked again before anything is concluded.
  defp job_for(socket, run_id) do
    Map.get(socket.assigns.queue, run_id) || Map.get(Jobs.by_run([run_id]), run_id)
  end

  defp wanted_follow(%{"follow" => value}, _socket) when value in ["true", "false"],
    do: value == "true"

  defp wanted_follow(_params, socket), do: not Map.get(socket.assigns, :follow, true)

  @impl true
  def handle_async(:delete, {:ok, count}, socket) do
    socket = assign(socket, deleting: nil)

    {:noreply,
     socket |> put_flash(:info, deleted(count)) |> load_runs(here_is_where_we_are(socket))}
  end

  def handle_async(:delete, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(deleting: nil)
     |> put_flash(:error, "The runs could not all be deleted: #{inspect(reason)}")}
  end

  # Stamped when the read is finished, not when it started: the window is the
  # time between two reads, so a page cannot read faster than it can rebuild —
  # which is what keeps a burst from becoming a backlog.
  defp refresh_now(socket) do
    {:noreply, refreshed} = refresh_own_run(socket)
    {:noreply, assign(refreshed, refreshed_at: System.monotonic_time(:millisecond))}
  end

  # One rebuild per burst: the first step of the next second is answered when it
  # arrives, and the ones behind it share the read it schedules.
  defp refresh_later(%{assigns: %{refresh_due: true}} = socket), do: socket

  defp refresh_later(socket) do
    Process.send_after(
      self(),
      :refresh_due,
      Map.get(socket.assigns, :refresh_ms, @refresh_after_ms)
    )

    assign(socket, refresh_due: true)
  end

  defp answered?(socket) do
    case socket.assigns[:refreshed_at] do
      nil -> false
      at -> System.monotonic_time(:millisecond) - at < @refresh_after_ms
    end
  end

  defp replay_tick(%{assigns: %{run: run, playing: true}} = socket) do
    next = socket.assigns.step + 1

    if Replay.last_step(run) != nil and next <= Replay.last_step(run) do
      {:noreply, socket |> replay_to(run, next) |> schedule_replay()}
    else
      {:noreply, assign(socket, playing: false)}
    end
  end

  defp replay_tick(socket), do: {:noreply, socket}

  defp refresh_own_run(%{assigns: %{live_action: :show, run: run}} = socket) when not is_nil(run),
    do: {:noreply, refresh_run(socket, run.id)}

  defp refresh_own_run(socket), do: {:noreply, socket}

  defp recorded(%{assigns: %{live_action: :index}} = socket, run),
    do: {:noreply, stream_insert(socket, :runs, run, at: 0)}

  defp recorded(socket, _run), do: {:noreply, socket}

  defp settled(%{assigns: %{live_action: :index}} = socket, run),
    do: {:noreply, stream_insert(socket, :runs, run)}

  defp settled(socket, _run), do: {:noreply, socket}

  defp replay_to(socket, run, step) do
    step = step |> max(Replay.first_step(run) || 0) |> min(Replay.last_step(run) || 0)
    assign_replay(socket, run, step) |> assign(playing: socket.assigns[:playing] || false)
  end

  defp replay_window(socket, window) do
    {chart, chart_key, chart_base} =
      chart_with(
        socket,
        socket.assigns.catalog,
        socket.assigns.series_id,
        window,
        socket.assigns.step
      )

    assign(socket,
      window: window,
      window_follows?: window == whole_run(socket.assigns.run),
      chart: chart,
      chart_key: chart_key,
      chart_base: chart_base
    )
  end

  defp schedule_replay(socket) do
    Process.send_after(self(), :replay_tick, replay_tick_ms())
    socket
  end

  defp replay_tick_ms, do: Application.get_env(:ex_tbp_monty, :studio_replay_tick_ms, 120)

  defp schedule_show_poll(socket) do
    if connected?(socket), do: Process.send_after(self(), :show_poll, @show_poll_ms)
    socket
  end

  # Asking the record — after a sweep, so a run nobody owns is settled instead
  # of shown as alive — is what stops the page from saying "running" while
  # nothing is running.
  # A record that says `running` is asked after, and the Reaper is asked too: a
  # run whose worker died, or whose job was cancelled out from under it, leaves
  # the word behind, and closing the record is what stops the page saying it.
  defp poll_shown_run(
         %{assigns: %{live_action: :show, run: %{id: id, status: "running"}}} = socket
       ) do
    # One run, asked about — not every open run: a run whose worker died, or whose
    # job was cancelled out from under it, leaves the word `running` behind, and
    # closing the record is what stops the page saying it. The record is polled
    # twice a second, so this has to be the cheap question.
    _ = Reaper.reap(id)

    socket |> refresh_run(id) |> keep_polling()
  end

  defp poll_shown_run(%{assigns: %{live_action: :show, run: %{id: id}}} = socket),
    do: socket |> refresh_run(id) |> keep_polling()

  defp poll_shown_run(socket), do: socket

  # A run that has stopped does not need asking again.
  defp keep_polling(socket) do
    if in_flight?(socket.assigns.run, socket.assigns.queue),
      do: schedule_show_poll(socket),
      else: socket
  end

  # Three zooms, named: a button sends a string, and turning arbitrary strings
  # into atoms is how a page leaks memory one click at a time.
  defp zoom_of("in"), do: :in
  defp zoom_of("out"), do: :out
  defp zoom_of(_all), do: :all

  defp parse_step(step) when is_integer(step), do: step

  defp parse_step(step) do
    case Integer.parse(to_string(step)) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  # From the list, the row simply goes; from one run's page there is nothing
  # left to look at, so the reader is taken back to the list.
  defp delete_run(%{assigns: %{live_action: :index}} = socket, run) do
    {:noreply, socket |> assign(confirming: nil) |> stream_delete(:runs, run)}
  end

  defp delete_run(socket, _run) do
    {:noreply, push_navigate(socket, to: ~p"/runs")}
  end

  # The same question as the one above, asked once for many. It says how many and
  # what they are — the ones picked, or everything the filter shows — because
  # "delete all" is the one place a list of hundreds can vanish.
  attr :confirming, :map, required: true

  defp confirm_bulk(assigns) do
    ~H"""
    <div
      id="confirm-bulk-delete"
      class="fixed inset-0 z-50 grid place-items-center bg-base-content/20 p-4"
      role="dialog"
      aria-modal="true"
    >
      <div class="w-full max-w-md space-y-3 rounded-box border border-base-300 bg-base-100 p-4">
        <h2 class="font-semibold">Delete {confirming_what(@confirming)}?</h2>
        <p class="text-sm text-base-content/70">
          {@confirming.count} run(s), with their config snapshots, inputs and
          logs. Files the runs produced stay where they are.
        </p>
        <div class="flex justify-end gap-2">
          <button id="cancel-bulk-delete" phx-click="cancel_bulk_delete" class="btn btn-ghost btn-sm">
            Keep them
          </button>
          <button id="confirm-bulk-delete-button" phx-click="bulk_delete" class="btn btn-error btn-sm">
            Delete {@confirming.count}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp confirming_what(%{scope: {:ids, _ids}}), do: "the selected runs"

  defp confirming_what(%{scope: {:matching, _filter}}),
    do: "every run this filter matches"

  defp confirming_what(%{scope: :done}), do: "every finished and stopped run"

  # What the filter matches, said as what the button does: it deletes every run
  # the filter matches, not the page of them on screen, and the label has to say
  # so — "delete all 1–25 of 77 shown" read as "these twenty-five".
  defp matching_delete_label("all", "", total), do: "Delete all #{total} runs"

  defp matching_delete_label(_state, _text, total),
    do: "Delete all #{total} matching"

  attr :run, :map, required: true

  defp confirm_delete(assigns) do
    ~H"""
    <div
      id="confirm-delete"
      class="fixed inset-0 z-50 grid place-items-center bg-base-content/20 p-4"
      role="dialog"
      aria-modal="true"
    >
      <div class="w-full max-w-md space-y-3 rounded-box border border-base-300 bg-base-100 p-4">
        <h2 class="font-semibold">Delete this run?</h2>
        <p class="text-sm text-base-content/70">
          <span class="font-mono">{@run.experiment}</span>
          and its config snapshot, inputs and log will be deleted. Files the run
          produced stay where they are.
        </p>
        <div class="flex justify-end gap-2">
          <button id="cancel-delete" phx-click="cancel_delete" class="btn btn-ghost btn-sm">
            Keep it
          </button>
          <button
            id="confirm-delete-button"
            phx-click="delete"
            phx-value-id={@run.id}
            class="btn btn-error btn-sm"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp inputs(%{inputs: inputs}) do
    inputs
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, format(value)} end)
  end

  # The config the run was started with, read back from its own snapshot: the
  # same sentences the experiment page promised before it was run, and the seed
  # the record kept rather than the one the config names. A record whose config
  # would not read back says nothing instead of guessing.
  defp configuration(%{config: config} = run) when is_map(config) and config != %{} do
    config
    |> Setup.new(name: run.experiment)
    |> Panel.facts(run.seed)
  rescue
    _unreadable -> []
  end

  defp configuration(_run), do: []

  defp summary(%{summary: summary}) when summary in [%{}, nil], do: []

  defp summary(%{summary: summary}) do
    summary
    |> Enum.reject(fn {key, value} ->
      key in @said_above or value in [%{}, []]
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, format(value)} end)
  end

  # What ended a run that did not finish. Absent is a real answer: a run that
  # finished, or one still going, has nothing that ended it. The record keeps the
  # sentence in one key and the traceback beside it in another, and both are
  # shown above; a summary grid that listed them again would repeat one and
  # unfold the other.
  defp failure(%{status: "failed", summary: summary}) when is_map(summary),
    do: Failure.explain(summary["reason"], summary["technical"])

  defp failure(_run), do: nil

  defp format(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format(value) when is_list(value), do: Enum.join(value, ", ")
  defp format(value), do: to_string(value)

  defp status_class("running"), do: "badge-info"
  defp status_class("queued"), do: "badge-info"
  defp status_class("finished"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class(_other), do: "badge-ghost"

  # How long a run has been quiet, in the unit that answers the question asked.
  defp quiet(run), do: Duration.humanize(RunHistory.quiet_for(run) * 1_000_000)

  # How much of the experiment this run is, and how much of that it did: "ep
  # 28/140" is the comparison a run is worth, and "ep 0" — the episode it
  # started at — said nothing about it.
  defp episodes_label(run) do
    ran = RunHistory.episodes_run(run)

    case RunHistory.episodes_asked(run) do
      nil -> "ep #{ran}"
      asked -> "ep #{ran}/#{asked}"
    end
  end

  # A file's size, in the unit a person reading a list of three files thinks in.
  defp bytes(size) when size >= 1_048_576, do: "#{Float.round(size / 1_048_576, 1)} MB"
  defp bytes(size) when size >= 1_024, do: "#{Float.round(size / 1_024, 1)} kB"
  defp bytes(size), do: "#{size} B"

  defp stopped_message(:stopping), do: "Stopping: the run ends after its next step."
  defp stopped_message(:settled), do: "Stopped: the run never started."

  # What state to show. A run's record is written the moment it is queued, so the
  # record says `running` before anything is running — the queue knows better.
  defp all_picked?(selected, page_ids),
    do: page_ids != [] and Enum.all?(page_ids, &MapSet.member?(selected, &1))

  # What state to show: a record is written the moment a run is queued, so the
  # word `running` on it means the job was picked up, and a job that has not
  # started yet is the one thing the queue knows better than the record.
  defp run_state(%{status: "running"}, %{state: state})
       when state in ~w(available scheduled retryable),
       do: "queued"

  defp run_state(run, _job), do: run.status

  # How far into its current episode a run is. Every episode restarts the step
  # counter, so the length of the whole log is not a step count: a run of seventy
  # seven episodes would claim step nine hundred of twelve.
  defp steps_into_episode(%{log: []}), do: 0

  defp steps_into_episode(%{log: log}) do
    episode = log |> List.last() |> Map.get("episode")
    Enum.count(log, &(Map.get(&1, "episode") == episode))
  end

  # In flight means both halves agree: the record says `running` *and* a job
  # still owns it. Either alone puts Stop in front of a run that is over.
  defp in_flight?(%{status: "running"} = run, queue), do: unfinished?(queue[run.id])
  defp in_flight?(_run, _queue), do: false

  defp running_now?(%{status: "running"} = run, queue), do: going?(queue[run.id])
  defp running_now?(_run, _queue), do: false

  defp unfinished?(nil), do: false
  defp unfinished?(%{state: state}), do: state in ~w(executing available scheduled retryable)
  defp going?(%{state: "executing"}), do: true
  defp going?(_not_running), do: false

  # The stop and end buttons exist on both pages, so the answer to "what
  # changed" is the page that is open, not the list.
  defp after_queue_change(%{assigns: %{live_action: :show, run: run}} = socket),
    do: refresh_run(socket, run.id)

  defp after_queue_change(socket), do: refresh_runs(socket)

  defp refresh_runs(socket) do
    runs = RunHistory.list()

    socket
    |> assign(queue: where_each_run_is(runs))
    |> stream(:runs, runs, reset: true)
  end

  defp filter_href(state, text), do: ~p"/runs?#{[state: state, q: text]}"

  defp page_href(page, state, text), do: ~p"/runs?#{[state: state, q: text, page: page]}"

  defp pill_class(true), do: "btn btn-xs btn-primary"
  defp pill_class(false), do: "btn btn-xs btn-ghost"

  # "1–25 of 240" for a list long enough to need saying, and "240 runs" for one
  # that is not.
  defp showing(_page, _per_page, 0), do: "no runs"

  defp showing(page, per_page, total) when total > per_page do
    first = (page - 1) * per_page + 1
    "#{first}–#{min(page * per_page, total)} of #{total}"
  end

  defp showing(_page, _per_page, 1), do: "1 run"
  defp showing(_page, _per_page, total), do: "#{total} runs"

  defp deleted(1), do: "Deleted one run."
  defp deleted(count), do: "Deleted #{count} runs."
end
