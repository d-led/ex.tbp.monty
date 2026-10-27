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

  alias Monty.Studio.{Replay, RunHistory}
  alias Monty.Studio.Replay.Chart

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
    case socket.assigns.live_action do
      :index -> {:noreply, stream(socket, :runs, RunHistory.list(), reset: true)}
      :show -> assign_run(params, socket)
    end
  end

  defp assign_run(%{"id" => id}, socket) do
    case RunHistory.get(id) do
      nil ->
        {:noreply,
         assign(socket, run: nil, moment: nil) |> put_flash(:error, "That run is gone.")}

      run ->
        {:noreply,
         socket
         |> assign(run: run)
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
      chart: Chart.new(series_points(series, series_id), window: window, playhead: step),
      playing: false
    )
  end

  defp whole_run(run) do
    {Replay.first_step(run) || 0, Replay.last_step(run) || 0}
  end

  defp default_series([first | _rest]), do: first.id
  defp default_series([]), do: nil

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
            inputs, and how it ended.
          </p>
        </div>
        <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Experiments</.link>
      </header>

      <ul
        id="runs"
        phx-update="stream"
        class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300 bg-base-100"
      >
        <li id="runs-empty" class="hidden only:block px-3 py-2 text-sm text-base-content/60">
          Nothing has run yet.
        </li>
        <li
          :for={{dom_id, run} <- @streams.runs}
          id={dom_id}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-1.5"
        >
          <.link navigate={~p"/runs/#{run.id}"} class="font-mono text-sm link link-hover">
            {run.experiment}
          </.link>
          <span class={["badge badge-sm", status_class(run.status)]}>{run.status}</span>
          <span class="text-xs text-base-content/60">
            {run.steps} steps · {duration(run.duration_us)} · {when_ran(run)}
          </span>
          <button
            id={"delete-#{run.id}"}
            phx-click="ask_delete"
            phx-value-id={run.id}
            class="btn btn-ghost btn-xs ms-auto text-error"
          >
            Delete
          </button>
        </li>
      </ul>

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
  defp status_class("finished"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class(_other), do: "badge-ghost"

  defp duration(microseconds) when is_integer(microseconds) and microseconds >= 1_000,
    do: "#{Float.round(microseconds / 1_000, 1)} ms"

  defp duration(microseconds), do: "#{microseconds || 0} µs"

  defp when_ran(%{inserted_at: nil}), do: "unknown"

  defp when_ran(%{inserted_at: inserted_at}) do
    inserted_at |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end
end
