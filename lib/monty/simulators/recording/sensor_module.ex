defmodule Monty.Simulators.Recording.SensorModule do
  @moduledoc """
  A sensor that replays a recording instead of sensing.

  A recorded episode is a sequence of percepts, one per step the real sensor had
  something to say — already in the cortical messaging protocol, because they
  were taken from Monty's own module input. There is nothing to sense and
  nothing to extract: this hands them back in order, one per step, and the
  runtime cannot tell the difference between it and a sensor looking at a world.

  It is a simulator-side module, like `Monty.Simulators.Synthetic.SensorModule`,
  so it is not part of the module map. What it is for is the one comparison a
  simulator cannot make: whether the *runtime*, not just the learning module,
  reproduces an episode Monty ran.

  A recording has more steps than it has percepts — the sensor is silent while
  the agent moves — so the queue holds a `nil` for every silent step, and
  `reset/1` rewinds to the beginning, which is how an episode can be replayed.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

  @type state :: %{
          sensor_module_id: atom() | String.t(),
          recorded: [Monty.Cmp.Message.t() | nil],
          percepts: [Monty.Cmp.Message.t() | nil]
        }

  @doc "A sensor that says what `percepts` says, in order, one step at a time."
  @spec new(atom() | String.t(), [Monty.Cmp.Message.t() | nil]) :: state()
  def new(sensor_module_id, percepts) do
    %{sensor_module_id: sensor_module_id, recorded: percepts, percepts: percepts}
  end

  @impl true
  def update_state(_agent_state, state), do: state

  @impl true
  def step(_observation, _motor_only?, state) do
    case state.percepts do
      [percept | rest] -> {percept, %{state | percepts: rest}}
      [] -> {nil, state}
    end
  end

  @impl true
  def reset(state), do: %{state | percepts: state.recorded}
end
