defmodule ExTbpMontyWeb.ExperimentLive do
  @moduledoc """
  One experiment: what it is before it runs, and what happened while it did.

  The page has three states and they are the same page. Before: the wiring
  diagram, the checks, and the modules it names. During: a row per timestep,
  streamed as the coordinator reports it, with the run's counters filling in.
  After: the summary, including any learning module that never received input —
  the failure that otherwise looks like success.
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Studio
  alias Monty.Studio.{Frames, Run, RunHistory, Setup, Summary}

  @impl true
  def mount(params, _session, socket) do
    case Studio.open(name_of(params)) do
      {:ok, opened} ->
        {:ok,
         socket
         |> assign(
           opened: opened,
           error: nil,
           run: nil,
           history: nil,
           summary: nil,
           infos: [],
           frames_sent: %{},
           ticking: false,
           steps: steps(params)
         )
         |> stream_configure(:steps, dom_id: &"steps-step-#{&1.step}")
         |> stream_configure(:log, dom_id: &"log-#{&1.step}")
         |> stream_configure(:frames, dom_id: &"frame-#{&1.sensor_id}")
         |> stream(:steps, [])
         |> stream(:log, [])
         |> stream(:frames, [])}

      {:error, reason} ->
        {:ok, assign(socket, opened: nil, error: reason, run: nil, summary: nil, infos: [])}
    end
  end

  @impl true
  def render(%{opened: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="experiment-missing" class="space-y-3">
        <h1 class="text-2xl font-semibold tracking-tight">That experiment will not open</h1>
        <p class="text-base-content/70">
          This config does not compose from Monty's conf tree: <code>{inspect(@error)}</code>
        </p>
        <.link navigate={~p"/"} class="btn btn-sm btn-outline">Back to the experiments</.link>
      </section>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header class="space-y-2">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="font-mono text-2xl font-semibold tracking-tight">{@opened.name}</h1>
          <span :if={@opened.source == :draft} class="badge badge-primary badge-sm">built here</span>
          <span :if={@opened.source == :monty} class="badge badge-ghost badge-sm">
            from Monty's conf
          </span>
        </div>
        <p class="max-w-3xl text-base-content/70">
          {@opened.setup.experiment_class.class} · {@opened.setup.monty_class.class}
        </p>
      </header>

      <dl class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        <ExTbpMontyWeb.StudioComponents.fact
          label="sensors"
          value={sensor_summary(@opened.setup)}
        />
        <ExTbpMontyWeb.StudioComponents.fact
          label="learning modules"
          value={learning_module_summary(@opened.setup)}
        />
        <ExTbpMontyWeb.StudioComponents.fact label="epochs" value={epochs(@opened.setup)} />
        <ExTbpMontyWeb.StudioComponents.fact label="ported here" value={ported(@opened.setup)} />
      </dl>

      <ExTbpMontyWeb.StudioComponents.diagram :if={@opened.diagram} diagram={@opened.diagram} />

      <ExTbpMontyWeb.StudioComponents.findings findings={@opened.setup.findings} />

      <section class="space-y-2">
        <header class="flex flex-wrap items-center gap-3">
          <h2 class="text-lg font-semibold tracking-tight">Run it</h2>
          <button
            id="run"
            phx-click="run"
            class="btn btn-primary btn-sm"
            disabled={!runable?(assigns)}
          >
            <.icon name="hero-play-mini" class="size-4" /> Run {@steps} steps
          </button>
          <button id="step" phx-click="step" class="btn btn-sm" disabled={!runable?(assigns)}>
            <.icon name="hero-forward-mini" class="size-4" /> One step
          </button>
          <button :if={@run} id="stop" phx-click="stop" class="btn btn-ghost btn-sm">Stop</button>
          <span :if={@run} id="run-progress" class="badge badge-ghost">
            step {@run.step} / {@run.steps}
          </span>
        </header>

        <p :if={not runable?(assigns)} id="run-blocked" class="text-sm text-error">
          Fix the errors above before running: this config would not start in Monty either.
        </p>

        <p :if={@run == nil and runable?(assigns)} class="text-sm text-base-content/60">
          A run uses the topology below with stand-in modules until the ported ones land: every
          sensor and learning module is its own supervised process, wired exactly as the config
          wires them.
        </p>

        <div id="frames" phx-update="stream" class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <p id="frames-empty" class="hidden only:block text-xs text-base-content/50">
            Sensor views appear here as the run steps.
          </p>
          <figure
            :for={{dom_id, frame} <- @streams.frames}
            id={dom_id}
            class="rounded-field border border-base-300 bg-base-100 p-1.5 text-base-content"
          >
            <figcaption class="flex items-baseline justify-between px-0.5 pb-1 text-[11px] text-base-content/60">
              <span class="font-mono">{frame.sensor_id}</span>
              <span>{frame.note}</span>
            </figcaption>
            <%!-- The frame is an SVG string this application generated, not
            content from a request. --%>
            <div class="text-base-content/80">{Phoenix.HTML.raw(frame.data)}</div>
          </figure>
        </div>

        <div id="steps" phx-update="stream" class="space-y-2">
          <p id="steps-empty" class="hidden only:block text-sm text-base-content/60">
            No timesteps yet.
          </p>
          <article
            :for={{dom_id, info} <- @streams.steps}
            id={dom_id}
            class="rounded-box border border-base-300 bg-base-100 p-2.5"
          >
            <div class="flex items-baseline justify-between gap-4">
              <h3 class="font-mono text-sm">step {info.step}</h3>
              <span class="text-xs text-base-content/60">
                {ExTbpMontyWeb.StudioComponents.duration(info.duration_us)}
              </span>
            </div>
            <dl class="mt-2 grid grid-cols-2 gap-x-6 gap-y-1 text-sm sm:grid-cols-4">
              <div>
                <dt class="text-base-content/60">percepts</dt>
                <dd class="font-mono">{inspect(info.percept_ids)}</dd>
              </div>
              <div>
                <dt class="text-base-content/60">inputs</dt>
                <dd class="font-mono">{inspect(info.inputs)}</dd>
              </div>
              <div>
                <dt class="text-base-content/60">votes</dt>
                <dd class="font-mono">
                  {info.votes.used}/{info.votes.sent}
                  <span :if={info.votes.deadline_hit?} class="badge badge-warning badge-sm ml-1">
                    deadline
                  </span>
                </dd>
              </div>
              <div>
                <dt class="text-base-content/60">goals</dt>
                <dd class="font-mono">{info.goals}</dd>
              </div>
            </dl>
          </article>
        </div>

        <div :if={@history} id="run-log-panel" class="space-y-1">
          <div class="flex items-center justify-between">
            <h3 class="text-sm font-medium">Log</h3>
            <.link navigate={~p"/runs/#{@history.id}"} id="open-history" class="btn btn-ghost btn-xs">
              History
            </.link>
          </div>
          <ul
            id="run-log"
            phx-update="stream"
            class="max-h-56 overflow-auto rounded-field border border-base-300 bg-base-100 p-2 font-mono text-[11px] leading-5"
          >
            <li id="run-log-empty" class="hidden only:block text-base-content/50">
              no timesteps yet
            </li>
            <li :for={{dom_id, entry} <- @streams.log} id={dom_id}>{entry.line}</li>
          </ul>
        </div>

        <ExTbpMontyWeb.StudioComponents.summary
          :if={@summary && @run && Run.finished?(@run)}
          summary={@summary}
        />
      </section>

      <section :if={@opened.yaml} class="space-y-2">
        <h2 class="text-lg font-semibold tracking-tight">The config</h2>
        <pre
          id="experiment-config"
          phx-no-curly-interpolation
          class="max-h-96 overflow-auto rounded-box border border-base-300 bg-base-100 p-3 font-mono text-xs"
        ><code><%= @opened.yaml %></code></pre>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("run", _params, %{assigns: %{opened: %{setup: setup}, steps: steps}} = socket) do
    if Setup.valid?(setup) do
      case Run.start(setup, steps: steps) do
        {:ok, run} ->
          socket =
            socket
            |> assign(run: run, infos: [], summary: nil, ticking: true)
            |> record_start()
            |> schedule_tick()

          {:noreply, advance(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not start: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("step", _params, %{assigns: %{run: nil, opened: %{setup: setup}}} = socket) do
    if Setup.valid?(setup), do: start_one_step(socket, setup), else: {:noreply, socket}
  end

  def handle_event("step", _params, %{assigns: %{run: nil}} = socket), do: {:noreply, socket}

  def handle_event("step", _params, socket), do: {:noreply, advance(socket)}

  def handle_event("stop", _params, socket), do: {:noreply, stop(socket)}

  @impl true
  def handle_info(:tick, %{assigns: %{ticking: true, run: run}} = socket) when run != nil do
    socket = advance(socket)

    if Run.finished?(socket.assigns.run) do
      {:noreply, stop(socket)}
    else
      {:noreply, schedule_tick(socket)}
    end
  end

  def handle_info(:tick, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if run = socket.assigns[:run], do: Run.stop(run)
    :ok
  end

  defp advance(%{assigns: %{run: run, infos: infos, opened: %{setup: setup}}} = socket) do
    {:ok, info, observations, run} = Run.step(run)
    infos = infos ++ [info]
    summary = Summary.from_infos(infos, setup)

    socket
    |> assign(run: run, infos: infos, summary: summary)
    |> stream_insert(:steps, info)
    |> send_frames(observations, info.step)
    |> record_step(info)
    |> maybe_finish(run, summary)
  end

  # Sensor frames are the most expensive thing a run sends, so they are
  # throttled per sensor (a view finder should not queue behind a patch
  # sensor). Everything about the policy lives in `Monty.Studio.Frames`.
  defp send_frames(%{assigns: %{opened: opened}} = socket, observations, step) do
    {frames, sent} =
      Frames.for_step(
        Setup.sensor_ids(opened.setup),
        observations,
        step,
        socket.assigns.frames_sent,
        now_ms(),
        Frames.throttle_ms()
      )

    frames
    |> Enum.reduce(assign(socket, frames_sent: sent), fn frame, socket ->
      stream_insert(socket, :frames, frame)
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_tick(socket) do
    Process.send_after(self(), :tick, tick_ms())
    assign(socket, ticking: true)
  end

  # A page drives its own clock; how fast is configurable so a test does not
  # speed up the experience to make it testable.
  defp tick_ms, do: Application.get_env(:ex_tbp_monty, :studio_tick_ms, 120)

  # The route is a glob, so the name arrives as its segments.
  defp name_of(%{"name" => segments}), do: segments |> List.wrap() |> Enum.join("/")
  defp name_of(_params), do: ""

  defp steps(params) do
    case Integer.parse(to_string(params["steps"] || "")) do
      {count, ""} when count > 0 -> count
      _default -> Run.default_steps()
    end
  end

  defp start_one_step(socket, setup) do
    case Run.start(setup, steps: socket.assigns.steps) do
      {:ok, run} ->
        socket = socket |> assign(run: run, infos: [], summary: nil) |> record_start()
        {:noreply, advance(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start: #{inspect(reason)}")}
    end
  end

  # -- history --------------------------------------------------------------

  # The record exists before the first step, so a run that is stopped, or whose
  # page is closed, still happened.
  defp record_start(%{assigns: %{opened: opened, steps: steps}} = socket) do
    attributes = %{
      experiment: opened.name,
      source: to_string(opened.source),
      steps: steps,
      seed: opened.setup.seed,
      config: opened.config,
      inputs: %{
        "groups" => opened.groups,
        "seed" => opened.setup.seed,
        "train_epochs" => opened.setup.epochs.train,
        "eval_epochs" => opened.setup.epochs.eval,
        "sensors" => Setup.sensor_ids(opened.setup),
        "learning_modules" => Enum.map(opened.setup.learning_modules, & &1.id)
      }
    }

    case RunHistory.start(attributes) do
      {:ok, history} -> assign(socket, history: history)
      {:error, _changeset} -> socket
    end
  end

  defp record_step(%{assigns: %{history: nil}} = socket, _info), do: socket

  defp record_step(%{assigns: %{history: history}} = socket, info) do
    entry = log_entry(info)

    case RunHistory.record_step(history, entry) do
      {:ok, history} ->
        socket
        |> assign(history: history)
        |> stream_insert(:log, %{step: info.step, line: log_line(entry)})

      {:error, _changeset} ->
        socket
    end
  end

  defp maybe_finish(%{assigns: %{history: nil}} = socket, _run, _summary), do: socket

  defp maybe_finish(socket, run, summary) do
    if Run.finished?(run) do
      {:ok, history} = RunHistory.finish(socket.assigns.history, summary_map(summary))
      assign(socket, history: history)
    else
      socket
    end
  end

  defp log_entry(info) do
    %{
      "step" => info.step,
      "percepts" => Enum.map(info.percept_ids, &to_string/1),
      "inputs" => Map.new(info.inputs, fn {module, count} -> {to_string(module), count} end),
      "votes" => %{"sent" => info.votes.sent, "used" => info.votes.used},
      "goals" => info.goals,
      "actions" => length(info.actions),
      "duration_us" => info.duration_us
    }
  end

  defp log_line(entry) do
    inputs =
      entry["inputs"]
      |> Enum.map_join(" ", fn {module, count} -> "#{module}=#{count}" end)

    "step #{entry["step"]} · percepts #{Enum.join(entry["percepts"], ",")} · " <>
      "inputs #{inputs} · votes #{entry["votes"]["used"]}/#{entry["votes"]["sent"]} · " <>
      "goals #{entry["goals"]} · #{ExTbpMontyWeb.StudioComponents.duration(entry["duration_us"])}"
  end

  defp summary_map(summary) do
    %{
      "steps" => summary.steps,
      "duration_us" => summary.duration_us,
      "deadline_hits" => summary.deadline_hits,
      "goals" => summary.goals,
      "votes_sent" => summary.votes_sent,
      "votes_used" => summary.votes_used,
      "actions" => summary.actions,
      "inputs" => summary.inputs,
      "never_updated" => summary.never_updated,
      "sensor_timeouts" => Enum.map(summary.sensor_timeouts, &to_string/1)
    }
  end

  defp stop(socket) do
    if run = socket.assigns[:run], do: Run.stop(run)
    assign(socket, ticking: false)
  end

  defp runable?(assigns) do
    case assigns[:opened] do
      nil -> false
      opened -> Setup.valid?(opened.setup)
    end
  end

  defp sensor_summary(setup), do: Enum.map_join(setup.sensors, ", ", & &1.id)

  defp learning_module_summary(setup),
    do: Enum.map_join(setup.learning_modules, ", ", & &1.id)

  defp epochs(setup), do: "train #{setup.epochs.train} · eval #{setup.epochs.eval}"

  defp ported(setup) do
    %{implemented: implemented, total: total} = Setup.ported(setup)
    "#{implemented}/#{total}"
  end
end
