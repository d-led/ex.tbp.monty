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

  alias ExTbpMonty.Core.SalienceNif
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.MapCombine
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.WeightedMean
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
    if by_kernel?(strategy) do
      call_by_kernel(strategy, ctx, rgba)
    else
      {features, lightness_pyramid} =
        rgba
        |> rgb()
        |> strategy.color_space_converter.()
        |> colour_features(strategy, ctx)

      features
      |> maybe_add_depth(strategy, ctx, depth)
      |> maybe_add_orientation(strategy, ctx, lightness_pyramid)
      |> then(&combine_and_normalise(strategy, &1))
    end
  end

  # The whole score in binaries, which is what Monty's `__call__` is: the image
  # into the colour space, a channel salience call per plane, and the combine —
  # four calls, and between them nothing but a plane. In Elixir the *crossings*
  # were the cost: 65 536 pixels a plane were packed, called, decoded and packed
  # again, 1.25 million times a step, and none of those values was read by
  # anything but the next kernel.
  #
  # Taken only for the shape every cows config has — the default colour space, no
  # depth and no orientation — because those three are where the plan of a call
  # would stop being one call per kernel.
  defp by_kernel?(%__MODULE__{} = strategy) do
    SalienceNif.loaded?() and strategy.color_space_converter == (&Images.rgb_to_opponent/1) and
      is_nil(strategy.depth) and is_nil(strategy.orientation) and
      match?(%WeightedMean{}, strategy.combine) and
      strategy.normalize == (&__MODULE__.range_normalize/1)
  end

  defp call_by_kernel(%__MODULE__{} = strategy, ctx, rgba) do
    height = length(rgba)
    width = rgba |> hd() |> length()
    bytes = width * height * 8

    planes = SalienceNif.opponent_planes(packed_rgba(rgba), width, height)

    maps =
      for plane <- 0..2, plane_bytes = binary_part(planes, plane * bytes, bytes) do
        Task.async(fn ->
          ColorChannelSalience.process_plane(strategy.color, ctx, plane_bytes, width, height)
        end)
      end
      |> Enum.map(&Task.await(&1, :infinity))

    [lightness, other_a, other_b] = maps

    %{"L" => lightness, "a" => other_a, "b" => other_b}
    |> then(&combine_and_normalise(strategy, &1, {width, height}))
  end

  defp packed_rgba(rgba) do
    for row <- rgba, pixel <- row, value <- pixel, into: <<>>, do: <<value * 1.0::float-little-64>>
  end

  @doc """
  The feature maps combined and normalised — the last pass over the whole map.

  Both steps are per-pixel, so the maps are packed once, weighted and summed in
  the order `WeightedMean` sums them, and normalised: one call instead of four
  passes. Anything else a config can name — another combiner, another
  normaliser, a machine with no crate — takes the reference below.
  """
  @spec combine_and_normalise(t(), map()) :: [[float()]]
  def combine_and_normalise(%__MODULE__{} = strategy, features),
    do: combine_and_normalise(strategy, features, nil)

  # `shape` is the view's, when the caller already has it: a map that is still a
  # binary cannot say how wide it is, and decoding it to find out is exactly what
  # this path exists to avoid.
  @doc false
  @spec combine_and_normalise(t(), map(), {pos_integer(), pos_integer()} | nil) :: [[float()]]
  def combine_and_normalise(%__MODULE__{} = strategy, features, shape) do
    with true <- SalienceNif.loaded?(),
         true <- strategy.normalize == (&__MODULE__.range_normalize/1),
         %WeightedMean{} = combine <- strategy.combine,
         {:ok, weighted} <- weighted_planes(features, combine),
         {:ok, width, height} <- plane_shape(weighted, shape) do
      by_combine_kernel(weighted, width, height)
    else
      _other -> combine_and_normalise_reference(strategy, features)
    end
  end

  @doc """
  The Elixir last pass: `combine` then `normalize`, whatever they are.

  Kept public because it is what the kernel is held to, and what runs where the
  crate was never built or the config names another combiner.
  """
  @spec combine_and_normalise_reference(t(), map()) :: [[float()]]
  def combine_and_normalise_reference(%__MODULE__{} = strategy, features) do
    features
    |> then(&combine(strategy.combine, &1))
    |> strategy.normalize.()
  end

  defp by_combine_kernel(weighted, width, height) do
    weights = for {weight, _plane} <- weighted, into: <<>>, do: <<weight::float-little-64>>

    weighted
    |> Enum.map_join(fn {_weight, plane} -> as_binary(plane) end)
    |> SalienceNif.combine_weighted(weights, width, height)
    |> then(fn raw -> for <<value::float-little-64 <- raw>>, do: value end)
    |> Enum.chunk_every(width)
  end

  # A feature map arrives as a binary when the channel that made it left it in
  # the encoding the kernel answers, and as rows when something in between read
  # it.
  defp as_binary(plane) when is_binary(plane), do: plane

  defp as_binary(plane) do
    for value <- List.flatten(plane), into: <<>>, do: <<value::float-little-64>>
  end

  defp plane_shape([{_weight, _map} | _rest], {width, height}), do: {:ok, width, height}

  defp plane_shape([{_weight, first} | _rest], nil) when is_list(first) do
    {:ok, first |> hd() |> length(), length(first)}
  end

  defp plane_shape(_weighted, _shape), do: :error

  # The weights in the order `WeightedMean` reads them off the map, so the sum
  # happens in the same order: `Enum.map` over the map, then the mean's total.
  defp weighted_planes(features, %WeightedMean{weights: weights}) do
    entries = Enum.map(features, fn {name, map} -> {Map.fetch(weights, name), map} end)

    if Enum.all?(entries, &match?({:ok, _weight}, elem(&1, 0))) do
      scales = Enum.map(entries, fn {{:ok, weight}, _map} -> weight end)
      total = scales |> Enum.map(&abs/1) |> Enum.sum()

      if total == 0.0 do
        :error
      else
        {:ok,
         entries
         |> Enum.map(fn {{:ok, weight}, map} -> {weight / total, map} end)}
      end
    else
      :error
    end
  end

  # A combiner is either a function — Monty's `map_mean` and friends — or one of
  # the configured structs, which answer through their own module.
  defp combine(combine, maps) when is_function(combine, 1), do: combine.(maps)
  defp combine(%module{} = combine, maps), do: module.call(combine, maps)

  defp rgb(rgba), do: Enum.map(rgba, fn row -> Enum.map(row, &Enum.take(&1, 3)) end)

  # The three channels are independent — same strategy, three planes, no shared
  # state and no draw from the episode's stream — so they run at once. The order
  # the results are taken in is the order the planes are in, so the map does not
  # depend on which channel finished first.
  #
  # The centre pyramid is asked for only when the strategy has orientation to
  # build from it: every other feature is a map of the view.
  defp colour_features(image, strategy, ctx) do
    [lightness, other_a, other_b] = channels(image)
    options = [pyramid?: strategy.orientation != nil]

    [{lightness_map, lightness_pyramid}, {a_map, _a_pyramid}, {b_map, _b_pyramid}] =
      [lightness, other_a, other_b]
      |> Enum.map(fn plane ->
        Task.async(fn -> ColorChannelSalience.process(strategy.color, ctx, plane, options) end)
      end)
      |> Enum.map(&Task.await(&1, :infinity))

    {%{"L" => lightness_map, "a" => a_map, "b" => b_map}, lightness_pyramid}
  end

  # One plane per channel, in a single pass over the image. Reading them apart —
  # `Enum.at(pixel, index)` for each channel — walked every pixel's list from the
  # front three times, and `Enum.at/2` on a list is a slice, not an index.
  defp channels(image) do
    {lightness, other_a, other_b} =
      Enum.reduce(image, {[], [], []}, fn row, {lightness, other_a, other_b} ->
        {l_row, a_row, b_row} =
          Enum.reduce(row, {[], [], []}, fn
            [l, a, b], {l_row, a_row, b_row} -> {[l | l_row], [a | a_row], [b | b_row]}
          end)

        {[Enum.reverse(l_row) | lightness], [Enum.reverse(a_row) | other_a],
         [Enum.reverse(b_row) | other_b]}
      end)

    [lightness, other_a, other_b] |> Enum.map(&Enum.reverse/1)
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
