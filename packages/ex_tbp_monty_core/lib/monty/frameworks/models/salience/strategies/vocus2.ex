defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2 do
  @moduledoc """
  VOCUS2: where in a view is worth looking, as one map of a number per pixel.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py`,
  and is the strategy a salience-configured experiment names. It builds a
  salience map out of four kinds of evidence and takes their weighted mean:

    * **`L`, `a`, `b`** — lightness and the two colour-opponent axes, each scored
      by `ColorChannelSalience`, so something is salient for being brighter,
      darker, redder or bluer than its surroundings;
    * **`depth`** — `DepthSalience`, so a nearer patch of surface stands out;
    * **`orientation`** — `OrientationSalience`, so an edge stands out whichever
      way it runs.

  The map is then normalised, because a caller compares salience values against
  each other and an unnormalised scale would depend on how bright and busy the
  view happened to be.

  ## The file's plain functions

  Two combiners and two normalisers are plain functions in Monty rather than
  classes, so they live here instead of in modules of their own: `map_max/1`,
  `map_sum/1`, `map_mean/1` combine named maps, and `no_normalize/1` /
  `range_normalize/1` normalise one.
  """

  @behaviour Monty.Frameworks.Models.Salience.Strategies.Protocol.SalienceStrategy

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.MapCombine
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.{
    ColorChannelSalience,
    DepthSalience,
    OrientationSalience,
    Vocus2SalienceConfig,
    WeightedMean
  }

  @doc "The strongest map at each pixel."
  @spec map_max(MapCombine.maps()) :: [[float()]]
  def map_max(maps), do: reduce(maps, &Enum.max/1)

  @doc "The sum of the maps at each pixel."
  @spec map_sum(MapCombine.maps()) :: [[float()]]
  def map_sum(maps), do: reduce(maps, &Enum.sum/1)

  @doc "The mean of the maps at each pixel."
  @spec map_mean(MapCombine.maps()) :: [[float()]]
  def map_mean(maps), do: reduce(maps, &(Enum.sum(&1) / length(&1)))

  defp reduce(maps, reducer) do
    maps
    |> Map.values()
    |> Enum.zip_with(fn rows -> Enum.zip_with(rows, reducer) end)
  end

  @doc "The map as it is."
  @spec no_normalize([[float()]]) :: [[float()]]
  def no_normalize(salience_map), do: salience_map

  @doc """
  The map rescaled so its lowest value is 0 and its highest is 1.

  A map that is already flat has no range to rescale and is clipped to `[0, 1]`
  instead, which keeps a constant map constant rather than dividing by zero.
  Monty asks `np.isclose(range, 0)`, whose tolerance against zero is `1.0e-8`.
  """
  @spec range_normalize([[float()]]) :: [[float()]]
  def range_normalize(salience_map) do
    values = List.flatten(salience_map)
    low = Enum.min(values)
    range = Enum.max(values) - low

    if abs(range) <= 1.0e-8 do
      Enum.map(salience_map, fn row -> Enum.map(row, &clip/1) end)
    else
      Enum.map(salience_map, fn row -> Enum.map(row, &((&1 - low) / range)) end)
    end
  end

  defp clip(value), do: value |> max(0.0) |> min(1.0)

  @default_converter &Images.rgb_to_opponent/1
  @default_combine %{"L" => 1, "a" => 1, "b" => 1, "depth" => 0.1, "orientation" => 1}

  @enforce_keys [:color]
  defstruct color: nil,
            depth: nil,
            orientation: nil,
            color_space_converter: @default_converter,
            combine: nil,
            normalize: &__MODULE__.range_normalize/1

  @type t :: %__MODULE__{
          color: ColorChannelSalience.t(),
          depth: DepthSalience.t() | nil,
          orientation: OrientationSalience.t() | nil,
          color_space_converter: ([[[float()]]] -> [[[float()]]]),
          combine: MapCombine.t(),
          normalize: ([[float()]] -> [[float()]])
        }

  @doc """
  A strategy from its parts.

  The combiner defaults to a weighted mean of `L`, `a`, `b` and `orientation` at
  1 and `depth` at 0.1. Depth is trusted less because a depth image's salience is
  dominated by the silhouette of whatever is in front, which is rarely where the
  interesting surface is.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      color: Keyword.fetch!(options, :color),
      depth: Keyword.get(options, :depth),
      orientation: Keyword.get(options, :orientation),
      color_space_converter: Keyword.get(options, :color_space_converter) || @default_converter,
      combine: Keyword.get(options, :combine) || WeightedMean.new(@default_combine),
      normalize: Keyword.get(options, :normalize) || (&__MODULE__.range_normalize/1)
    }
  end

  @doc """
  A strategy from a config, with its channels configured to agree with each other.

  The depth channel takes the colour channel's sigmas, and the orientation channel
  a period of twice the centre sigma — both Monty's choices, and both of them
  choices a single config should not be able to make inconsistently.
  """
  @spec from_config(Vocus2SalienceConfig.t(), keyword()) :: t()
  def from_config(%Vocus2SalienceConfig{} = config, options \\ []) do
    new(
      color:
        ColorChannelSalience.new(
          center_sigma: config.center_sigma,
          surround_sigma: config.surround_sigma,
          n_scales: config.n_scales,
          max_octaves: config.max_octaves
        ),
      depth: if(config.use_depth, do: depth_salience(config)),
      orientation:
        if(config.use_orientation, do: OrientationSalience.new(period: 2 * config.center_sigma)),
      color_space_converter: Keyword.get(options, :color_space_converter),
      combine: Keyword.get(options, :combine),
      normalize: Keyword.get(options, :normalize, &__MODULE__.range_normalize/1)
    )
  end

  defp depth_salience(config) do
    DepthSalience.new(
      center_sigma: config.center_sigma,
      surround_sigma: config.surround_sigma,
      n_scales: config.n_scales,
      max_octaves: config.max_octaves
    )
  end

  @impl Monty.Frameworks.Models.Salience.Strategies.Protocol.SalienceStrategy
  @doc """
  The salience of a view: one number per pixel of `depth`.

  The colour image is converted to the strategy's colour space and its three
  channels scored one at a time; depth and orientation are scored too when the
  strategy has them; then everything is combined and normalised. Alpha is
  dropped, because Monty's camera writes a constant there.
  """
  @spec call(t(), Monty.Context.t(), [[[float()]]], [[float()]]) :: [[float()]]
  def call(%__MODULE__{} = strategy, %Monty.Context{} = ctx, rgba, depth) do
    {features, lightness_pyramid} =
      rgba
      |> rgb()
      |> strategy.color_space_converter.()
      |> colour_features(strategy, ctx)

    features
    |> maybe_add_depth(strategy, ctx, depth)
    |> maybe_add_orientation(strategy, ctx, lightness_pyramid)
    |> then(&combine(strategy.combine, &1))
    |> strategy.normalize.()
  end

  # A combiner is either a function — Monty's `map_mean` and friends — or one of
  # the configured structs, which answer through their own module.
  defp combine(combine, maps) when is_function(combine, 1), do: combine.(maps)
  defp combine(%module{} = combine, maps), do: module.call(combine, maps)

  defp rgb(rgba), do: Enum.map(rgba, fn row -> Enum.map(row, &Enum.take(&1, 3)) end)

  defp colour_features(image, strategy, ctx) do
    [lightness, other_a, other_b] = channels(image)

    {lightness_map, lightness_pyramid} =
      ColorChannelSalience.process(strategy.color, ctx, lightness)

    {a_map, _a_pyramid} = ColorChannelSalience.process(strategy.color, ctx, other_a)
    {b_map, _b_pyramid} = ColorChannelSalience.process(strategy.color, ctx, other_b)

    {%{"L" => lightness_map, "a" => a_map, "b" => b_map}, lightness_pyramid}
  end

  # One plane per channel: the pixels' first elements, then their second, ...
  defp channels(image) do
    for index <- 0..2 do
      Enum.map(image, fn row -> Enum.map(row, &Enum.at(&1, index)) end)
    end
  end

  defp maybe_add_depth(features, %__MODULE__{depth: nil}, _ctx, _depth), do: features

  defp maybe_add_depth(features, strategy, ctx, depth) do
    Map.put(features, "depth", DepthSalience.process(strategy.depth, ctx, depth))
  end

  defp maybe_add_orientation(features, %__MODULE__{orientation: nil}, _ctx, _pyramid),
    do: features

  defp maybe_add_orientation(features, strategy, ctx, %Pyramid{} = lightness_pyramid) do
    Map.put(
      features,
      "orientation",
      OrientationSalience.process(strategy.orientation, ctx, lightness_pyramid)
    )
  end
end
