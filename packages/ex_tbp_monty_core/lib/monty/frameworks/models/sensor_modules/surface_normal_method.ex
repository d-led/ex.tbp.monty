defmodule Monty.Frameworks.Models.SensorModules.SurfaceNormalMethod do
  @moduledoc """
  How a sensor module estimates a surface normal from a patch.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::SurfaceNormalMethod`,
  which is an enum of three names: total least squares (the default Monty's
  experiments use), ordinary least squares, and a naive cross product of
  neighbouring pixels.

  Only total least squares is ported — it is the one Monty's configurations ask
  for, and the only one `Monty.Frameworks.Utils.SensorProcessing` implements.
  Asking for another is an error rather than a silent substitution: a normal
  estimated a different way is a different percept.
  """

  @type t :: :tls

  @doc """
  The method a config names, which is `"TLS"` unless it says otherwise.
  """
  @spec new(String.t() | t() | nil) :: t()
  def new(nil), do: :tls
  def new(:tls), do: :tls

  def new(method) when method in ["TLS", "tls"], do: :tls

  def new(method) when method in ["OLS", "ols", "naive", "NAIVE"] do
    raise ArgumentError,
          "surface normal method #{inspect(method)} is not ported; only total least squares "
  end
end
