defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.Vocus2SalienceConfig do
  @moduledoc """
  The numbers a VOCUS2 strategy is configured from.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::Vocus2SalienceConfig`.

  One config produces the colour, depth and orientation channels together,
  because they have to agree: the orientation period is twice the centre sigma
  and the depth channel uses the same sigmas as the colour channels, so setting
  them separately would be a way to configure a strategy that does not work.
  """

  @enforce_keys []
  defstruct center_sigma: 3.0,
            surround_sigma: 5.0,
            n_scales: 2,
            max_octaves: 5,
            use_depth: true,
            use_orientation: true

  @type t :: %__MODULE__{
          center_sigma: float(),
          surround_sigma: float(),
          n_scales: pos_integer(),
          max_octaves: pos_integer() | nil,
          use_depth: boolean(),
          use_orientation: boolean()
        }

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      center_sigma: Keyword.get(options, :center_sigma, 3.0),
      surround_sigma: Keyword.get(options, :surround_sigma, 5.0),
      n_scales: Keyword.get(options, :n_scales, 2),
      max_octaves: Keyword.get(options, :max_octaves, 5),
      use_depth: Keyword.get(options, :use_depth, true),
      use_orientation: Keyword.get(options, :use_orientation, true)
    }
  end
end
