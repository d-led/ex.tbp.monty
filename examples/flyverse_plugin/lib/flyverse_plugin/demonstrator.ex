defmodule FlyversePlugin.Demonstrator do
  @moduledoc """
  A four-neuron network with two channels in and two out — the pack this example
  runs when nobody has the dataset.

  ```
      left drive  (0) --#{200}--> left readout  (2)
      right drive (1) --#{200}--> right readout (3)
  ```

  Every constant here is a statement about four neurons and nothing else. They
  are chosen so that a drive of a few hundred hertz on one side makes the
  readout on that side fire within the #{200} ticks of a window — a weight of 200
  contacts is 55 mV of conductance at flyverse's 0.275 mV per contact, which is
  what it takes to carry a resting neuron at −52 mV past its −45 mV threshold
  across the 1.8 ms axonal delay. The dataset's own weights are the dataset's.

  Written by `mix flyverse_plugin.pack <directory>`; `FlyversePlugin.Pack`
  writes it in flyverse's format, and the test opens it with flyverse's loader.
  """

  @contacts 200
  @ticks 200

  @doc """
  The pack spec: body IDs in model order, signed edges, and the plan.

  One body ID per neuron and one driver per side, so that a plan names the same
  indices a four-neuron network obviously has.
  """
  @spec spec() :: FlyversePlugin.Pack.spec()
  def spec do
    %{
      neuron_ids: [1, 2, 3, 4],
      edges: [{0, 2, @contacts}, {1, 3, @contacts}],
      plan: %{
        "drives" => [[0], [1]],
        "readouts" => [[2], [3]],
        "ticks" => @ticks,
        "seed" => 7
      }
    }
  end
end
