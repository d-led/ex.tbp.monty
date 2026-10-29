defmodule Monty.Frameworks.Utils.SensorProcessing do
  @moduledoc """
  What a sensor module makes of a depth image.

  Mirrors `tbp/monty/frameworks/utils/sensor_processing.py`, which is a file of
  functions rather than classes — the curvature estimation, the patch
  normalisation, the surface normalisation. What is ported so far:

    * `log_sign/1` — **ported**: a signed logarithm, which is how a curvature
      becomes a feature a learning module can average.

  And one function that file does not have but its module uses:

    * `rgb2hsv/1` — reproduced from `skimage.color.rgb2hsv`, which is what
      `CameraSM` calls to turn the centre pixel into Monty's `hsv` feature. It
      is here rather than in the simulator because a simulator that invented its
      own hue would train a learning module on a different feature from Monty's.

  Still planned: `principal_curvatures/5`, `surface_normals/3` and the rest of
  the depth processing. Until they are, a sensor reads the geometry a world
  reports rather than estimating it from a depth image, which is what
  `Monty.Simulators.Synthetic.SensorModule` does.
  """

  @doc """
  A signed logarithm: `sign(x) * ln(|x| + 1)`.

  Monty's `log_sign`, which scales a curvature without losing which way the
  surface bends — a convex surface has negative principal curvatures, and a
  plain logarithm would lose that. The `+ 1` keeps values near zero from
  running off to negative infinity.

      iex> Monty.Frameworks.Utils.SensorProcessing.log_sign(0.0)
      0.0

      iex> Monty.Frameworks.Utils.SensorProcessing.log_sign(-1.0)
      -0.6931471805599453
  """
  @spec log_sign(number() | [number()]) :: float() | [float()]
  def log_sign(value) when is_number(value) do
    sign = if value < 0, do: -1.0, else: 1.0
    sign * :math.log(abs(value) + 1.0)
  end

  def log_sign(values) when is_list(values), do: Enum.map(values, &log_sign/1)

  @doc """
  One `rgb` pixel as hue, saturation and value, each in `0..1`.

  `skimage.color.rgb2hsv`, whose conventions this follows: hue is the angle
  round the colour wheel divided by 360, so red is 0, green a third and blue two
  thirds; saturation is how far the colour is from grey; value is the brightest
  channel. A grey pixel has no hue to speak of and skimage answers 0 for it, as
  this does.

      iex> Monty.Frameworks.Utils.SensorProcessing.rgb2hsv([1.0, 0.0, 0.0])
      [0.0, 1.0, 1.0]
  """
  @spec rgb2hsv([number()]) :: [float()]
  def rgb2hsv([red, green, blue]) do
    brightest = max(red, max(green, blue))
    darkest = min(red, min(green, blue))
    delta = brightest - darkest

    [hue(red, green, blue, brightest, delta), saturation(brightest, delta), brightest]
  end

  defp saturation(brightest, _delta) when brightest == 0.0, do: 0.0

  defp saturation(brightest, delta), do: delta / brightest

  # No spread between the channels means no hue: the pixel is grey.
  defp hue(_red, _green, _blue, _brightest, delta) when delta == 0.0, do: 0.0

  defp hue(red, green, blue, brightest, delta) do
    degrees =
      cond do
        brightest == red -> 60.0 * (green - blue) / delta
        brightest == green -> 60.0 * ((blue - red) / delta + 2.0)
        true -> 60.0 * ((red - green) / delta + 4.0)
      end

    # A red-dominant pixel can come out negative: the wheel wraps at red.
    wrap(degrees / 360.0)
  end

  defp wrap(hue) when hue < 0.0, do: wrap(hue + 1.0)
  defp wrap(hue) when hue >= 1.0, do: wrap(hue - 1.0)
  defp wrap(hue), do: hue
end
