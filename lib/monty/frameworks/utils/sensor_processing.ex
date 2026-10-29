defmodule Monty.Frameworks.Utils.SensorProcessing do
  @moduledoc """
  What a sensor module makes of a depth image.

  Mirrors `tbp/monty/frameworks/utils/sensor_processing.py`, which is a file of
  functions rather than classes — the curvature estimation, the patch
  normalisation, the surface normalisation. What is ported so far:

    * `log_sign/1` — **ported**: a signed logarithm, which is how a curvature
      becomes a feature a learning module can average.

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
end
