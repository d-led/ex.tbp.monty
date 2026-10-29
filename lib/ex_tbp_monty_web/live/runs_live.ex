defmodule ExTbpMontyWeb.RunsLive do
  @moduledoc """
  A live view of one synthetic Monty run.

  The page exists to prove the runtime is observable: every step is a real
  timestep through the supervised module processes, and what the coordinator
  reports — percepts, learning-module inputs, votes used, goals, actions — is
  streamed to the page as it happens.

  The run is started per browser session under `ExTbpMonty.ModelSupervisor`,
  and the page drives the clock (one step per click) so a test never has to
  wait for a timer.
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Frameworks.Models.SensorModules.CameraSM
  alias Monty.Runtime.Model
  alias Monty.Simulators.Synthetic.{Environment, LearningModule, Motor}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, topic())

    {:ok,
     assign(socket, model: nil, step: 0, environment: nil, pending_actions: [])
     |> stream(:steps, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="mx-auto max-w-4xl space-y-6">
        <header class="space-y-2">
          <h1 class="text-3xl font-semibold tracking-tight">Monty runtime</h1>
          <p class="text-base-content/70">
            A synthetic run: one sensor module, one learning module and a motor system,
            each its own supervised process. Every click advances exactly one timestep.
          </p>
        </header>

        <div class="flex flex-wrap items-center gap-3">
          <button id="start" phx-click="start" class="btn btn-primary">
            <.icon name="hero-play-mini" class="size-4" /> Start run
          </button>
          <button id="step" phx-click="step" class="btn" disabled={is_nil(@model)}>
            <.icon name="hero-forward-mini" class="size-4" /> Step
          </button>
          <span :if={@model} class="badge badge-ghost">model {inspect(@model)}</span>
          <span :if={@model} class="badge badge-ghost">next step {@step}</span>
        </div>

        <div id="steps" phx-update="stream" class="space-y-2">
          <p id="steps-empty" class="hidden only:block text-base-content/60">
            No steps yet — start the run and step the clock.
          </p>
          <article
            :for={{dom_id, info} <- @streams.steps}
            id={dom_id}
            class="rounded-box border border-base-300 bg-base-100 p-4"
          >
            <div class="flex items-baseline justify-between gap-4">
              <h2 class="font-mono text-sm">step {info.step}</h2>
              <span class="text-xs text-base-content/60">{info.duration_us} µs</span>
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
            <p class="mt-2 font-mono text-xs text-base-content/70">{inspect(info.actions)}</p>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("start", _params, socket) do
    model_id = "model-#{System.unique_integer([:positive])}"

    spec = %{
      model_id: model_id,
      sensor_modules: [
        %{
          id: :patch,
          agent_id: Environment.agent_id(),
          module: CameraSM,
          state: CameraSM.new(:patch, features: ["on_object", "hsv"])
        }
      ],
      learning_modules: [%{id: :lm_0, module: LearningModule, state: LearningModule.new(:lm_0)}],
      sm_to_lm: %{lm_0: [:patch]},
      lm_to_lm_vote: %{lm_0: []},
      motor: {Motor, Motor.new()}
    }

    {:ok, _pid} = DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec})

    {:noreply,
     socket
     |> assign(
       model: model_id,
       step: 0,
       environment: Environment.new([:patch]),
       pending_actions: []
     )
     |> advance()}
  end

  def handle_event("step", _params, %{assigns: %{model: nil}} = socket), do: {:noreply, socket}

  def handle_event("step", _params, socket), do: {:noreply, advance(socket)}

  @impl true
  def handle_info({:monty_step, info}, socket) do
    {:noreply, stream_insert(socket, :steps, info)}
  end

  @impl true
  def terminate(_reason, socket) do
    if model = socket.assigns[:model], do: Model.stop(model)
    :ok
  end

  defp advance(socket) do
    {observations, proprioceptive_state, environment} =
      Environment.step(socket.assigns.environment, socket.assigns.pending_actions)

    {:ok, actions, info} =
      Model.step(socket.assigns.model, observations, proprioceptive_state, Monty.Context.new(42))

    info = Map.put(info, :id, "step-#{info.step}")

    # Insert locally so the click that caused the step renders it, and broadcast
    # so every other viewer of this run sees it too. Inserting the same stream
    # id twice updates the row, so the local copy is not duplicated.
    Phoenix.PubSub.broadcast(ExTbpMonty.PubSub, topic(), {:monty_step, info})

    socket
    |> stream_insert(:steps, info)
    |> assign(step: socket.assigns.step + 1, environment: environment, pending_actions: actions)
  end

  defp topic, do: "monty:demo"
end
