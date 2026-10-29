defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.DepthSalience do
  @moduledoc """
  How much a patch of surface stands out in *depth*.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::DepthSalience`.
  VOCUS2 is a colour attention model; this is the extension that makes it work
  on depth, and it is why a salience config can care about a shape rather than a
  colour.

  Two details carry the meaning:

    * the depth is first replaced by its **negative logarithm**, so a depth
      difference is read as a *ratio*. On a log scale a step from 10 cm to 11 cm
      is as interesting as one from 1 m to 1.1 m, which is not true of raw
      depth and is what makes a distant object as findable as a near one;
    * a depth of zero means "nothing there", and its negative logarithm is
      minus infinity — Monty maps the infinities to zero. On a log-depth scale
      zero is *above* every real depth, so an empty pixel reads as the nearest
      patch in the view rather than as an absence. That is what the code does,
      it is reproduced here on purpose, and `docs/monty-bugs.md` §1.14 records
      why it is probably not what was meant.

  Only the brighter side of the difference is kept, because depth has no "dark
  side": a log-depth above its surround is a nearer patch, which is salient; a
  log-depth below is merely further away.
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
            collapse: &Pyramids.collapse_mean/1,
            operating_limits: nil

  @type t :: %__MODULE__{
          center_sigma: float(),
          surround_sigma: float(),
          n_scales: pos_integer(),
          max_octaves: pos_integer() | nil,
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
      collapse: Keyword.get(options, :collapse, &Pyramids.collapse_mean/1),
      operating_limits: Keyword.get_lazy(options, :operating_limits, &SafeOperatingLimits.new/0)
    }
  end

  @doc "The depth salience map: where the surface is nearer than its surroundings."
  @spec process(t(), Monty.Context.t(), [[float()]]) :: [[float()]]
  def process(%__MODULE__{} = salience, %Monty.Context{} = ctx, image) do
    check_limits!(salience, ctx, image)

    log_depth = Enum.map(image, fn row -> Enum.map(row, &negative_log/1) end)

    {center, surround} =
      Pyramids.center_surround(log_depth,
        center_sigma: salience.center_sigma,
        surround_sigma: salience.surround_sigma,
        n_scales: salience.n_scales,
        max_octaves: salience.max_octaves
      )

    center
    |> Pyramid.subtract(surround)
    |> Pyramid.apply(&brighter/1)
    |> salience.collapse.()
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

  # `-log(depth)`, with a depth of zero — nothing there — answering zero rather
  # than an infinity. Monty gets there with `np.nan_to_num(..., posinf=0)`, and
  # this port reproduces the consequence as well as the arithmetic: zero is the
  # top of the log-depth scale, so an empty pixel is the nearest patch in the
  # view. `docs/monty-bugs.md` §1.14.
  defp negative_log(depth) when depth == 0.0, do: 0.0
  defp negative_log(depth), do: -:math.log(depth)

  defp brighter(plane) do
    Enum.map(plane, fn row -> Enum.map(row, &max(&1, 0.0)) end)
  end
end
