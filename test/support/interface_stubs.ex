defmodule Monty.InterfaceStubs do
  @moduledoc """
  A world and two transforms that say what the environment interface did to them.

  `scripts/record_monty_interface.py` ran Monty's own `Interface` with a stub world
  that counts its steps and transforms that tag the observations. These are the
  same two, so the port's sequence can be put beside Monty's: `StubWorld` answers
  `"after N steps"`, and `Tagging` reports what it was handed before passing the
  observations on.
  """

  defmodule StubWorld do
    @moduledoc """
    A world that counts its steps, and answers which step it is on.

    The count is a field rather than a process, because a world in this port is a
    value: stepping it answers the world it leaves behind.
    """

    defstruct step: 0, actions: []

    def step(%__MODULE__{} = world, actions) do
      names =
        Enum.map(actions, fn action -> action.__struct__ |> Module.split() |> List.last() end)

      {%{"observations" => ["after #{world.step + 1} steps"]}, %{"state" => "stepped"},
       %{world | step: world.step + 1, actions: world.actions ++ [names]}}
    end
  end

  defmodule Tagging do
    @moduledoc """
    Tags the observations, and reports the pose and the stream it was given.

    A real transform reads both; this one says so, so a test can check that every
    transform in a chain is handed a pose and a stream — and what the previous one
    left for it to read.
    """

    defstruct [:name]

    def call(observations, %{name: name}, ctx) do
      send(self(), {:saw, name, observations["observations"], ctx.state != nil, ctx.rng != nil})

      Map.update!(observations, "observations", &(&1 ++ [name]))
    end
  end
end
