defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.ColorChannelSalience do
  @moduledoc """
  How much one colour channel stands out from its own surroundings.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::ColorChannelSalience`.

  The whole idea in three steps: blur the channel a little (centre) and a lot
  (surround); subtract, so only what the wide blur could not explain is left;
  and keep the two sides of that difference as separate pyramids — `on`, where
  the centre is brighter, and `off`, where it is darker — before combining them.
  Splitting the two matters because a dark patch on a bright background and a
  bright patch on a dark one are both salient, and a plain difference would let
  them cancel each other in the combination.

  Returns the feature map and the centre pyramid, because the orientation channel
  is computed from the lightness pyramid rather than from the map.
  """

  require Logger

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.{OperatingLimits, SafeOperatingLimits}
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  @enforce_keys []
  defstruct center_sigma: 2.0,
            surround_sigma: 3.0,
            n_scales: 2,
            max_octaves: nil,
            combine: &Pyramids.combine_mean/1,
            collapse: &Pyramids.collapse_mean/1,
            operating_limits: nil

  @type t :: %__MODULE__{
          center_sigma: float(),
          surround_sigma: float(),
          n_scales: pos_integer(),
          max_octaves: pos_integer() | nil,
          combine: ([Pyramid.t()] -> Pyramid.t()),
          collapse: (Pyramid.t() -> [[float()]]),
          operating_limits: OperatingLimits.t()
        }

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      center_sigma: Keyword.get(options, :center_sigma, 2.0),
      surround_sigma: Keyword.get(options, :surround_sigma, 3.0),
      n_scales: Keyword.get(options, :n_scales, 2),
      max_octaves: Keyword.get(options, :max_octaves),
      combine: Keyword.get(options, :combine, &Pyramids.combine_mean/1),
      collapse: Keyword.get(options, :collapse, &Pyramids.collapse_mean/1),
      operating_limits: Keyword.get_lazy(options, :operating_limits, &SafeOperatingLimits.new/0)
    }
  end

  @doc """
  The salience of one colour channel, and the centre pyramid it came from.

  The image must be a single channel in `[0, 1]`. A config outside the operating
  limits either raises or, when the run suppresses runtime errors, is used
  anyway with a warning — which is Monty's behaviour, and is how a large image
  can be tried with sigmas nobody has validated.
  """
  @spec process(t(), Monty.Context.t(), [[float()]]) :: {[[float()]], Pyramid.t()}
  def process(%__MODULE__{} = salience, %Monty.Context{} = ctx, image) do
    check_limits!(salience, ctx, image)

    {center, surround} =
      Pyramids.center_surround(image,
        center_sigma: salience.center_sigma,
        surround_sigma: salience.surround_sigma,
        n_scales: salience.n_scales,
        max_octaves: salience.max_octaves
      )

    difference = Pyramid.subtract(center, surround)

    feature_pyramid =
      salience.combine.([
        Pyramid.apply(difference, &brighter/1),
        Pyramid.apply(difference, &darker/1)
      ])

    {salience.collapse.(feature_pyramid), center}
  end

  defp check_limits!(salience, ctx, image) do
    smallest = min(length(image), image |> hd() |> length())
    limits = salience.operating_limits

    case limits.__struct__.validate(
           limits,
           smallest,
           salience.center_sigma,
           salience.surround_sigma
         ) do
      :ok -> :ok
      {:error, message} -> refuse(ctx, message)
    end
  end

  defp refuse(%Monty.Context{suppress_runtime_errors: true}, message) do
    Logger.warning(message)
  end

  defp refuse(_ctx, message), do: raise(ArgumentError, message)

  # The two sides of the difference: `on` keeps where the centre is brighter,
  # `off` where it is darker.
  defp brighter(plane) do
    Enum.map(plane, fn row -> Enum.map(row, &max(&1, 0.0)) end)
  end

  defp darker(plane) do
    Enum.map(plane, fn row -> Enum.map(row, &max(-&1, 0.0)) end)
  end
end
