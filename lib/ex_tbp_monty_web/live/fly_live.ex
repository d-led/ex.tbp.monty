defmodule ExTbpMontyWeb.FlyLive do
  @moduledoc """
  A fly's body: walk it, and watch where Monty's own actions take it.

  A fly is not a scene with a camera in it. Its body is FlyGym's NeuroMechFly in
  MuJoCo, stepped by `priv/monty_py/fly_peer.py` in an interpreter a machine
  supplies, and what it answers is where it got to and what its two compound eyes
  read. `Monty.Simulators.Flygym.World` is that body, and
  `Monty.SensorModules.Transforms.Ommatidia` is what turns its eyes into a
  percept.

  So this page is the whole bridge in one place: press a direction, the body
  walks, and the page shows the path it took, the heading it now has, and the
  numbers its eyes reported. Nothing here changes an experiment — a run reaches a
  world through its config, and Monty's configs name MuJoCo — so the page is the
  walk-through rather than a new config key.

  ## Why it starts nothing until asked

  A body is an operating-system process running MuJoCo. Starting one on mount
  would cost every visitor one; the first press starts it, and leaving the page
  stops it.
  """

  use ExTbpMontyWeb, :live_view

  require Logger

  alias Monty.Frameworks.Actions.OrientHorizontal
  alias Monty.Geometry.Rotation
  alias Monty.SensorModules.SensorModule.{Payload, TransformContext}
  alias Monty.SensorModules.Transforms.Ommatidia
  alias Monty.Simulators.Flygym.World

  @agent "agent_id_0"

  # What a press asks for: a stride at the body's own pace, and a turn small
  # enough that a few of them make a path worth looking at.
  @stride 0.005
  @turn 25.0

  # How many of the eye's numbers the page draws. A fly has 721 per side; a row of
  # bars is a shape, not a datum.
  @drawn 24

  # The smallest walk the drawing will show: one press of a stride is half a
  # centimetre, and a dot in the middle would say nothing about where it went.
  @minimum_span_mm 10.0

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       available?: World.available?(),
       reason: World.unavailable_reason(),
       installed_path: World.installed_path(),
       stride: @stride,
       turn: @turn,
       drawn: @drawn,
       body: nil,
       steps: [],
       age_ms: nil,
       percept: nil
     )}
  end

  @impl true
  def handle_event("forward", _params, socket), do: {:noreply, walk(socket, 0.0, @stride)}

  def handle_event("left", _params, socket), do: {:noreply, walk(socket, @turn, 0.0)}

  def handle_event("right", _params, socket), do: {:noreply, walk(socket, -@turn, 0.0)}

  def handle_event("reset", _params, socket) do
    World.stop(socket.assigns.body)

    {:noreply,
     socket
     |> assign(body: nil, steps: [], age_ms: nil, percept: nil)
     |> put_flash(:info, "The body starts where its own gait stands it up.")}
  end

  # A client event this page does not answer keeps the page drawing rather than
  # taking the LiveView down.
  def handle_event(event, params, socket) do
    Logger.debug(fn -> "fly page ignored #{event}: #{inspect(params)}" end)
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    World.stop(socket.assigns[:body])
    :ok
  end

  defp walk(socket, turn, stride) do
    started = System.monotonic_time(:millisecond)
    body = socket.assigns.body || World.reset(World.new())

    {observations, state, body} = World.step(body, [orient(turn, stride)])
    agent = Map.fetch!(state, @agent)

    assign(socket,
      body: body,
      steps: socket.assigns.steps ++ [step(agent)],
      percept: percept(observations, agent),
      age_ms: System.monotonic_time(:millisecond) - started
    )
  end

  defp orient(turn, stride) do
    %OrientHorizontal{
      agent_id: @agent,
      rotation_degrees: turn,
      left_distance: 0.0,
      forward_distance: stride
    }
  end

  # What a sensor module does with the body's report: one transform, and the
  # percept it makes.
  defp percept(observations, agent) do
    context = %TransformContext{agent_state: agent}

    {payload, _transform} =
      Ommatidia.new() |> Ommatidia.call(context, %Payload{observation: observations[@agent]})

    payload.percept
  end

  # One press, as the page remembers it: where the fly is and which way it faces.
  defp step(agent) do
    {w, x, y, z} = Rotation.to_quaternion(agent.rotation)

    %{
      x: Enum.at(agent.position, 0),
      y: Enum.at(agent.position, 1),
      heading: :math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) * 180 / :math.pi()
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-8">
        <.header>
          A fly's body, walked by Monty's own actions
          <:subtitle>
            The body is FlyGym's NeuroMechFly in MuJoCo. A press sends Monty's
            <code>OrientHorizontal</code>
            — a turn and a stride — and the body answers where it got
            to and what its two compound eyes read.
          </:subtitle>
        </.header>

        <%= if @available? do %>
          <div id="fly-controls" class="mt-6 flex flex-wrap items-center gap-3">
            <button
              id="fly-forward"
              phx-click="forward"
              phx-disable-with="walking…"
              class="btn btn-primary"
            >
              Forward {round(@stride * 1000)} mm
            </button>
            <button id="fly-left" phx-click="left" phx-disable-with="turning…" class="btn">
              Turn left {trunc(@turn)}°
            </button>
            <button id="fly-right" phx-click="right" phx-disable-with="turning…" class="btn">
              Turn right {trunc(@turn)}°
            </button>
            <button id="fly-reset" phx-click="reset" class="btn btn-ghost">Stand it up again</button>
            <span :if={@age_ms} class="text-sm opacity-70">the body took {@age_ms} ms</span>
          </div>

          <div class="mt-6 grid gap-6 lg:grid-cols-2">
            <section id="fly-path" class="card bg-base-200 p-4">
              <h2 class="font-semibold">Where it walked</h2>
              <p :if={@steps == []} class="mt-2 text-sm opacity-70">
                Nothing yet — press Forward and the path starts here.
              </p>
              <svg :if={@steps != []} viewBox="0 0 300 200" class="mt-2 h-64 w-full">
                <polyline
                  points={sketch(@steps).points}
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                />
                <circle cx={sketch(@steps).x} cy={sketch(@steps).y} r="4" fill="currentColor" />
              </svg>
              <p :if={@steps != []} class="mt-2 text-sm">
                {length(@steps)} presses, {metres(last(@steps).x)}, {metres(last(@steps).y)} m from
                where it stood, facing {round(last(@steps).heading)}°
              </p>
            </section>

            <section id="fly-eyes" class="card bg-base-200 p-4">
              <h2 class="font-semibold">What the eyes read</h2>
              <p :if={@percept == nil} class="mt-2 text-sm opacity-70">
                Nothing yet — the eyes report after the first step.
              </p>
              <p :if={@percept} class="mt-2 text-sm">
                {readings(@percept)} numbers per step: one per ommatidium per photoreceptor type, both
                eyes. The bars are the first {@drawn}.
              </p>
              <div :if={@percept} id="fly-eye-bars" class="mt-3 flex h-24 items-end gap-1">
                <div
                  :for={{value, index} <- Enum.with_index(Enum.take(readings_list(@percept), @drawn))}
                  id={"fly-eye-#{index}"}
                  class="flex-1 rounded-t bg-primary"
                  style={"height: #{round(clamp(value) * 100)}%"}
                />
              </div>
              <p class="mt-4 text-sm opacity-70">
                <code>Monty.SensorModules.Transforms.Ommatidia</code> makes the percept: the
                readings become one feature, the fly's own position becomes the location, and its
                own facing becomes the pose — because a compound eye has no depth to put a surface
                point at.
              </p>
            </section>
          </div>
        <% else %>
          <div id="fly-unavailable" class="alert mt-6">
            <div>
              <p class="font-semibold">This node has no interpreter with the fly body in it.</p>
              <p class="mt-2 text-sm">{@reason}</p>
              <p class="mt-2 text-sm">Make one and name it, then open this page again:</p>
              <pre class="mt-2 overflow-x-auto rounded bg-base-300 p-3 text-xs"><code phx-no-curly-interpolation>python3 -m venv "{Path.dirname(Path.dirname(@installed_path))}"
    "{@installed_path}" -m pip install flygym</code></pre>
              <p class="mt-2 text-sm opacity-70">
                The body's interpreter is a separate one on purpose: FlyGym installs MuJoCo 3.16 and
                this application's own interpreter is pinned to 4.0.1, so the two cannot share one.
              </p>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp readings(%{non_morphological_features: %{"ommatidia" => readings}}), do: length(readings)

  defp readings_list(%{non_morphological_features: %{"ommatidia" => readings}}), do: readings

  # The path in the drawing: a body's walk is centimetres, so the box is the
  # walk's own extent scaled to fill it — one scale for both axes, so the shape is
  # true — and a fly that has barely moved still draws something.
  defp sketch(steps) do
    xs = Enum.map(steps, &(&1.x * 1000))
    ys = Enum.map(steps, &(&1.y * 1000))

    span = max(max(Enum.max(xs) - Enum.min(xs), Enum.max(ys) - Enum.min(ys)), @minimum_span_mm)
    scale = 140 / span
    centre_x = (Enum.min(xs) + Enum.max(xs)) / 2
    centre_y = (Enum.min(ys) + Enum.max(ys)) / 2

    %{
      points:
        Enum.map_join(steps, " ", fn step ->
          "#{draw_x(step, centre_x, scale)},#{draw_y(step, centre_y, scale)}"
        end),
      x: draw_x(last(steps), centre_x, scale),
      y: draw_y(last(steps), centre_y, scale)
    }
  end

  defp draw_x(step, centre, scale), do: round(150 + (step.x * 1000 - centre) * scale)
  defp draw_y(step, centre, scale), do: round(100 - (step.y * 1000 - centre) * scale)

  defp last(steps), do: List.last(steps)

  defp clamp(value) when is_number(value), do: min(max(value, 0.0), 1.0)
  defp clamp(_value), do: 0.0

  defp metres(value) when is_number(value), do: :erlang.float_to_binary(value, decimals: 4)
  defp metres(_value), do: "0.0000"
end
