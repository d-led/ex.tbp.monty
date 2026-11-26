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

  alias ExTbpMonty.Core.SalienceNif
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

    if SalienceNif.loaded?(),
      do: by_kernel(salience, image),
      else: reference(salience, image)
  end

  @doc """
  The Elixir channel: the reference the kernel is held to.

  Kept public because it is what the parity case compares against, and what runs
  where the crate was never built.
  """
  @spec reference(t(), [[float()]]) :: {[[float()]], Pyramid.t()}
  def reference(%__MODULE__{} = salience, image) do
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

  # A channel blurs twenty-seven planes twice over and collapses them back to
  # one, and every plane crossing the boundary on its own was most of a cows
  # step's second. The whole channel is one call: the octave shapes and every
  # sigma are resolved here, so the kernel does arithmetic and nothing else.
  defp by_kernel(%__MODULE__{} = salience, image) do
    height = length(image)
    width = image |> hd() |> length()
    scales = salience.n_scales

    shapes =
      for {rows, columns} <- Pyramids.octave_shapes({height, width}, salience.max_octaves),
          into: <<>>,
          do: <<columns::little-32, rows::little-32>>

    scale_sigmas =
      for scale <- 1..scales, into: <<>> do
        <<Pyramids.sigma_difference(salience.center_sigma, scale, scales)::float-little-64>>
      end

    surround_sigmas =
      for scale <- 0..(scales - 1), into: <<>> do
        sigma = :math.sqrt(salience.surround_sigma ** 2 - salience.center_sigma ** 2)
        <<sigma * :math.pow(2.0, scale / scales)::float-little-64>>
      end

    plane = for row <- image, value <- row, into: <<>>, do: <<value::float-little-64>>

    {map, centres, centre_shapes} =
      SalienceNif.channel_salience(
        plane,
        shapes,
        salience.center_sigma * 1.0,
        scale_sigmas,
        surround_sigmas,
        2.5
      )

    centre = centres |> planes(centre_shapes) |> Enum.chunk_every(scales) |> Pyramid.new()

    {rows(map, width), centre}
  end

  # Rows come out of the binary directly: `Enum.chunk_every/2` on a 65 536-value
  # list is a Stream over the whole plane, and the shape is already known.
  defp rows(raw, width) do
    for <<row::binary-size(^width * 8) <- raw>> do
      for <<value::float-little-64 <- row>>, do: value
    end
  end

  # Each plane's own shape says how many bytes it takes, so each is decoded from
  # its own stretch of the binary: decoding all of them and then splitting the
  # list per plane walked the rest of the values once per plane.
  defp planes(raw, shapes) do
    shapes
    |> then(fn binary ->
      for <<columns::little-32, rows::little-32 <- binary>>, do: {rows, columns}
    end)
    |> Enum.map_reduce(0, fn {rows, columns}, offset ->
      bytes = rows * columns * 8
      plane = binary_part(raw, offset, bytes)

      cut =
        for <<row::binary-size(^columns * 8) <- plane>>,
          do: for(<<v::float-little-64 <- row>>, do: v)

      {cut, offset + bytes}
    end)
    |> elem(0)
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
