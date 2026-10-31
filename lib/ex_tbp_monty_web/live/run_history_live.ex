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

  alias Monty.Studio.{Artifacts, Jobs, Replay, RunHistory}
  alias Monty.Studio.Jobs.Reaper
  alias Monty.Studio.Replay.Chart

  # The states a run can be in, in the order the filter pills read them.
  @states ~w(running finished stopped failed)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(confirming: nil)
     |> stream_configure(:log, dom_id: &"log-#{&1["step"]}")
     |> stream_configure(:runs, dom_id: &"run-#{&1.id}")
     |> stream(:runs, [])
     |> stream(:log, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Before anything is read: a `running` record whose process is gone is not a
    # run in flight, and a page that showed it as one would be wrong twice —
    # about the run and about whether a new one can start.
    _ = Reaper.sweep()

    case socket.assigns.live_action do
      :index -> {:noreply, load_runs(socket, params)}
      :show -> assign_run(params, socket)
    end
  end

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

    socket
    |> assign(
      state: state,
      states: @states,
      text: text,
      page: found.page,
      pages: found.pages,
      per_page: found.per_page,
      total: found.total,
      counts: RunHistory.counts(),
      queue: where_each_run_is(found.runs)
    )
    |> stream(:runs, found.runs, reset: true)
  end

  defp state_of(%{"state" => state}) when state in @states, do: state
  defp state_of(_params), do: "all"

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

  defp assign_run(%{"id" => id}, socket) do
    case RunHistory.get(id) do
      nil ->
        {:noreply,
         assign(socket, run: nil, moment: nil) |> put_flash(:error, "That run is gone.")}

      run ->
        {:noreply,
         socket
         |> assign(run: run)
         |> assign(files: Artifacts.files(run.id))
         |> stream(:log, run.log, reset: true)
         |> assign_replay(run, Replay.last_step(run))}
    end
  end

  # The replay starts where the run ended: a person opening a finished run wants
  # to see what it came to, and rewinding is one drag away.
  defp assign_replay(socket, run, step) do
    step = step || Replay.first_step(run)
    series = Replay.series(run)
    series_id = socket.assigns[:series_id] || default_series(series)
    window = Replay.window(run, socket.assigns[:window] || whole_run(run))

    socket
    |> assign(
      moment: Replay.at(run, step),
      step: step,
      series: series,
      series_id: series_id,
      window: window,
      pictures: Replay.pictures?(run),
      chart: Chart.new(series_points(series, series_id), window: window, playhead: step),
      playing: false
    )
  end

  defp whole_run(run) do
    {Replay.first_step(run) || 0, Replay.last_step(run) || 0}
  end

  # The chart opens on the curve an episode is judged by — the evidence, which
  # climbs to a recognition or does not — rather than on a sensor's x, which for a
  # world behind the port barely moves.
  defp default_series(series) do
    Enum.find_value(series, first_id(series), fn
      %{id: "evidence"} -> "evidence"
      _other -> nil
    end)
  end

  defp first_id([first | _rest]), do: first.id
  defp first_id([]), do: nil

  defp series_points(series, id) do
    case Enum.find(series, &(&1.id == id)) do
      nil -> []
      found -> found.points
    end
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
        <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Experiments</.link>
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

      <div class="overflow-hidden rounded-box border border-base-300 bg-base-100">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs text-base-content/60">
              <th class="w-full">experiment</th>
              <th>state</th>
              <th class="text-right">steps</th>
              <th class="text-right">duration</th>
              <th>started</th>
              <th class="text-right"></th>
            </tr>
          </thead>
          <tbody id="runs" phx-update="stream">
            <tr id="runs-empty" class="hidden only:table-row">
              <td colspan="6" class="text-sm text-base-content/60">
                No run matches.
                <.link patch={filter_href(@state, "")} class="link link-primary">Clear the filter</.link>
              </td>
            </tr>
            <tr :for={{dom_id, run} <- @streams.runs} id={dom_id}>
              <td class="w-full">
                <.link navigate={~p"/runs/#{run.id}"} class="link link-hover font-mono text-sm">
                  {run.experiment}
                </.link>
              </td>
              <td>
                <span class={["badge badge-sm", status_class(run_state(run, @queue[run.id]))]}>
                  {run_state(run, @queue[run.id])}
                </span>
              </td>
              <td class="text-right font-mono text-xs">{run.steps}</td>
              <td class="text-right font-mono text-xs">{duration(run.duration_us)}</td>
              <td class="font-mono text-xs">{when_ran(run)}</td>
              <td class="text-right whitespace-nowrap">
                <%!-- Two ways out: a run that is stepping ends at its next step of
                its own accord, one stuck in a step has to be ended. --%>
                <button
                  :if={unfinished?(@queue[run.id])}
                  id={"stop-#{run.id}"}
                  phx-click="stop"
                  phx-value-id={run.id}
                  class="btn btn-ghost btn-xs text-warning"
                  title="Stop it at its next step"
                >
                  Stop
                </button>
                <button
                  :if={going?(@queue[run.id])}
                  id={"end-#{run.id}"}
                  phx-click="end_now"
                  phx-value-id={run.id}
                  class="btn btn-ghost btn-xs text-error"
                  title="End it now"
                >
                  End now
                </button>
                <button
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
          <span class={["badge badge-sm", status_class(@run.status)]}>{@run.status}</span>
          <span class="badge badge-ghost badge-sm">{@run.source}</span>
          <button
            id={"delete-#{@run.id}"}
            phx-click="ask_delete"
            phx-value-id={@run.id}
            class="btn btn-ghost btn-xs ms-auto text-error"
          >
            Delete
          </button>
        </div>
        <p class="text-xs text-base-content/60">
          started {when_ran(@run)} · {@run.steps} steps · {duration(@run.duration_us)}
        </p>
      </header>

      <%!-- A run that did not finish says why, in the words of whatever stopped
      it: the worker's own message when it could record one, the reaper's when
      the process died with no chance to. A person reading this page should never
      have to ask "was it interrupted?". --%>
      <section
        :if={failure(@run)}
        id="run-failure"
        class="rounded-field border border-error/40 bg-error/10 px-3 py-2"
      >
        <p class="text-sm font-medium">This run did not finish.</p>
        <p class="mt-0.5 font-mono text-xs break-words text-base-content/80">{failure(@run)}</p>
      </section>

      <section :if={@run == nil} class="text-base-content/70">
        <p>That run is gone.</p>
        <.link navigate={~p"/runs"} class="btn btn-sm btn-outline">All runs</.link>
      </section>

      <section :if={@run} class="grid gap-3 lg:grid-cols-2">
        <div class="space-y-1">
          <h2 class="text-sm font-medium">Inputs</h2>
          <dl class="overflow-hidden rounded-box border border-base-300 bg-base-100 text-xs">
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

      <section :if={@run} id="replay-panel" class="space-y-1">
        <ExTbpMontyWeb.StudioComponents.replay
          moment={@moment}
          chart={@chart}
          series={@series}
          series_id={@series_id}
          pictures={@pictures}
          recorded={length(Replay.steps(@run))}
          playing={@playing}
        />
      </section>

      <section :if={@run} class="space-y-1">
        <h2 class="text-sm font-medium">Log</h2>
        <ul
          id="run-log"
          phx-update="stream"
          class="max-h-[28rem] overflow-auto rounded-box border border-base-300 bg-base-100 p-2 font-mono text-[11px] leading-5"
        >
          <li id="run-log-empty" class="hidden only:block text-base-content/50">no steps recorded</li>
          <li :for={{dom_id, entry} <- @streams.log} id={dom_id}>{log_line(entry)}</li>
        </ul>
      </section>

      <section :if={@run} class="space-y-1">
        <h2 class="text-sm font-medium">Artefacts</h2>
        <p :if={@files == []} id="run-files-empty" class="text-xs text-base-content/60">
          This run wrote no files. Its log says which classes its config asked for and
          which of them this port does not have.
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
              class="link link-hover font-mono text-primary"
            >
              {file.name}
            </.link>
            <span class="ms-auto font-mono text-base-content/50">{bytes(file.bytes)}</span>
          </li>
        </ul>
      </section>

      <section :if={@run} class="space-y-1">
        <h2 class="text-sm font-medium">Config snapshot</h2>
        <pre
          id="run-config"
          phx-no-curly-interpolation
          class="max-h-80 overflow-auto rounded-box border border-base-300 bg-base-100 p-3 font-mono text-[11px]"
        ><code><%= @run.config |> Jason.encode!(pretty: true) %></code></pre>
      </section>

      <.confirm_delete :if={@confirming} run={@confirming} />
    </Layouts.app>
    """
  end

  # Typing in the filter is a navigation: the address carries it, so a narrowed
  # list is shareable and the back button undoes it.
  def handle_event("filter", %{"q" => text}, socket) do
    {:noreply, push_patch(socket, to: filter_href(socket.assigns.state, text))}
  end

  def handle_event("ask_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: RunHistory.get(id))}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %{} = run <- RunHistory.get(id),
         {:ok, _deleted} <- RunHistory.delete(run) do
      forget(socket, run)
    else
      _already_gone -> {:noreply, assign(socket, confirming: nil)}
    end
  end

  # Stopping a run that is waiting cancels it outright; one that is stepping ends
  # at its next step and writes its own summary. Ending is for a run stuck inside
  # a step, which nothing but ending the process will release.
  def handle_event("stop", %{"id" => run_id}, socket) do
    with %{id: job_id} <- socket.assigns.queue[run_id],
         {:ok, ended} <- Jobs.cancel(job_id) do
      {:noreply, socket |> put_flash(:info, stopped_message(ended)) |> refresh_runs()}
    else
      _nothing_to_stop ->
        {:noreply,
         socket
         |> put_flash(:error, "That run had already finished — nothing was stopped.")
         |> refresh_runs()}
    end
  end

  def handle_event("end_now", %{"id" => run_id}, socket) do
    with %{id: job_id} <- socket.assigns.queue[run_id],
         {:ok, _settled} <- Jobs.halt(job_id) do
      {:noreply,
       socket |> put_flash(:info, "Ended: the run stopped where it was.") |> refresh_runs()}
    else
      _not_running ->
        {:noreply,
         socket
         |> put_flash(:error, "That run is not running — there is nothing to end.")
         |> refresh_runs()}
    end
  end

  # -- the replay ------------------------------------------------------------

  @impl true
  def handle_event("replay_seek", %{"step" => step}, %{assigns: %{run: run}} = socket) do
    {:noreply, replay_to(socket, run, parse_step(step))}
  end

  def handle_event("replay_step", %{"delta" => delta}, %{assigns: %{run: run}} = socket) do
    {:noreply, replay_to(socket, run, socket.assigns.step + parse_step(delta))}
  end

  def handle_event("replay_play", _params, %{assigns: %{run: run}} = socket) do
    socket =
      if Replay.last_step(run) == socket.assigns.step do
        # Playing a run that is already at its end starts again from the top,
        # which is what a person who pressed play wanted.
        socket |> replay_to(run, Replay.first_step(run))
      else
        socket
      end

    {:noreply, assign(socket, playing: true) |> schedule_replay()}
  end

  def handle_event("replay_pause", _params, socket) do
    {:noreply, assign(socket, playing: false)}
  end

  def handle_event("replay_zoom", %{"zoom" => zoom}, %{assigns: %{run: run}} = socket) do
    window = Replay.zoom(run, socket.assigns.window, socket.assigns.step, zoom_of(zoom))
    {:noreply, replay_window(socket, window)}
  end

  def handle_event("replay_series", %{"series" => id}, socket) do
    {:noreply,
     assign(socket, series_id: id)
     |> replay_window(socket.assigns.window)}
  end

  @impl true
  def handle_info(:replay_tick, %{assigns: %{run: run, playing: true}} = socket) do
    next = socket.assigns.step + 1

    if Replay.last_step(run) != nil and next <= Replay.last_step(run) do
      {:noreply, socket |> replay_to(run, next) |> schedule_replay()}
    else
      {:noreply, assign(socket, playing: false)}
    end
  end

  def handle_info(:replay_tick, socket), do: {:noreply, socket}

  defp replay_to(socket, run, step) do
    step = step |> max(Replay.first_step(run) || 0) |> min(Replay.last_step(run) || 0)
    window = Replay.window(run, socket.assigns.window)
    assign_replay(socket, run, step) |> assign(window: window)
  end

  defp replay_window(socket, window) do
    points = series_points(socket.assigns.series, socket.assigns.series_id)

    assign(socket,
      window: window,
      chart: Chart.new(points, window: window, playhead: socket.assigns.step)
    )
  end

  defp schedule_replay(socket) do
    Process.send_after(self(), :replay_tick, replay_tick_ms())
    socket
  end

  defp replay_tick_ms, do: Application.get_env(:ex_tbp_monty, :studio_replay_tick_ms, 120)

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
  defp forget(%{assigns: %{live_action: :index}} = socket, run) do
    {:noreply, socket |> assign(confirming: nil) |> stream_delete(:runs, run)}
  end

  defp forget(socket, _run) do
    {:noreply, push_navigate(socket, to: ~p"/runs")}
  end

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
          and its config snapshot, inputs and log will be forgotten. Files the run
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

  defp summary(%{summary: summary}) when summary in [%{}, nil], do: []

  defp summary(%{summary: summary}) do
    summary
    |> Enum.reject(fn {_key, value} -> value in [%{}, []] end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, format(value)} end)
  end

  # What ended a run that did not finish. Absent is a real answer: a run that
  # finished, or one still going, has nothing that ended it.
  defp failure(%{status: "failed", summary: summary}) when is_map(summary),
    do: summary["reason"]

  defp failure(_run), do: nil

  defp format(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format(value) when is_list(value), do: Enum.join(value, ", ")
  defp format(value), do: to_string(value)

  defp log_line(entry) do
    inputs =
      entry
      |> Map.get("inputs", %{})
      |> Enum.map_join(" ", fn {module, count} -> "#{module}=#{count}" end)

    votes = Map.get(entry, "votes", %{})

    "step #{entry["step"]} · percepts #{Enum.join(Map.get(entry, "percepts", []), ",")} · " <>
      "inputs #{inputs} · votes #{votes["used"]}/#{votes["sent"]} · goals #{entry["goals"]}"
  end

  defp status_class("running"), do: "badge-info"
  defp status_class("queued"), do: "badge-info"
  defp status_class("finished"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class(_other), do: "badge-ghost"

  defp duration(microseconds) when is_integer(microseconds) and microseconds >= 1_000,
    do: "#{Float.round(microseconds / 1_000, 1)} ms"

  defp duration(microseconds), do: "#{microseconds || 0} µs"

  # A file's size, in the unit a person reading a list of three files thinks in.
  defp bytes(size) when size >= 1_048_576, do: "#{Float.round(size / 1_048_576, 1)} MB"
  defp bytes(size) when size >= 1_024, do: "#{Float.round(size / 1_024, 1)} kB"
  defp bytes(size), do: "#{size} B"

  defp when_ran(%{inserted_at: nil}), do: "unknown"

  defp when_ran(%{inserted_at: inserted_at}) do
    inserted_at |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp stopped_message(:stopping), do: "Stopping: the run ends after its next step."
  defp stopped_message(:settled), do: "Stopped: the run never started."

  # What state to show. A run's record is written the moment it is queued, so the
  # record says `running` before anything is running — the queue knows better.
  defp run_state(%{status: "running"}, %{state: state})
       when state in ~w(available scheduled retryable),
       do: "queued"

  defp run_state(run, _not_yet_started), do: run.status

  defp unfinished?(nil), do: false
  defp unfinished?(%{state: state}), do: state in ~w(executing available scheduled retryable)
  defp going?(%{state: "executing"}), do: true
  defp going?(_not_running), do: false

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

  defp showing(_page, _per_page, total), do: "#{total} run(s)"
end
