defmodule Monty.Math do
  @moduledoc """
  The constants Monty's arithmetic agrees on.

  Mirrors `tbp/monty/math.py`, which is little more than the tolerances every
  geometric comparison uses. They live in one place because a tolerance that
  differs between two modules is a disagreement about what "the same direction"
  means, and that disagreement shows up as a hypothesis surviving in one module
  and not in another.

  Monty's type aliases (`VectorXYZ`, `EulerAnglesXYZ`, `QuaternionWXYZ`) have no
  Elixir counterpart: a `[x, y, z]` is a list and a quaternion is a
  `Monty.Geometry.Rotation`, so the aliases would only restate their own types.
  """

  @identity_quaternion {1.0, 0.0, 0.0, 0.0}
  @zero_vector {0.0, 0.0, 0.0}
  @ones_vector {1.0, 1.0, 1.0}
  @default_tolerance 1.0e-6
  @rotation_tolerance_radians 1.0e-6

  @doc "The quaternion `wxyz` of no rotation."
  @spec identity_quaternion() :: {float(), float(), float(), float()}
  def identity_quaternion, do: @identity_quaternion

  @doc "The vector `(0, 0, 0)`."
  @spec zero_vector() :: {float(), float(), float()}
  def zero_vector, do: @zero_vector

  @doc "The vector `(1, 1, 1)`."
  @spec ones_vector() :: {float(), float(), float()}
  def ones_vector, do: @ones_vector

  @doc """
  How close two lengths or dot products must be to count as equal.

  Monty's `DEFAULT_TOLERANCE`. It is a distance, not a relative error: halves of
  a metre compare at this scale, and comparisons of larger quantities scale it
  by their own magnitude at the call site.
  """
  @spec default_tolerance() :: float()
  def default_tolerance, do: @default_tolerance

  @doc "How small an angle (in radians) counts as no rotation."
  @spec rotation_tolerance_radians() :: float()
  def rotation_tolerance_radians, do: @rotation_tolerance_radians

  @doc """
  An angle in degrees as radians.

  Monty writes this conversion out at each use (`math.radians`, or `* pi / 180`
  inside scipy calls); the arithmetic is the same either way, and having one
  copy means a tolerance in degrees and a tolerance in radians cannot drift
  apart.
  """
  @spec degrees(number()) :: float()
  def degrees(degrees), do: degrees * :math.pi() / 180

  @doc """
  The average of a sample, or zero for an empty one.

  numpy's `np.mean`, which Monty uses to summarise evidence and locations. The
  empty case is Monty's own convention for a hypothesis space with nothing in
  it: no observations, no average, and zero is the neutral value to add to.
  """
  @spec mean([number()]) :: float()
  def mean([]), do: 0.0
  def mean(values), do: Enum.sum(values) / length(values)

  @doc """
  The spread of a sample around its mean, dividing by `n`.

  numpy's `np.std` — population standard deviation, not the sample estimate.
  Monty uses it to decide whether one object stands out from the field: a wide
  spread means there is something to discriminate between.
  """
  @spec population_std([number()]) :: float()
  def population_std([]), do: 0.0

  def population_std(values) do
    average = mean(values)

    values
    |> Enum.map(fn value -> (value - average) * (value - average) end)
    |> mean()
    |> :math.sqrt()
  end

  @doc "The value moved inside `[low, high]`, numpy's `np.clip`."
  @spec clip(number(), number(), number()) :: number()
  def clip(value, low, high), do: value |> max(low) |> min(high)
end
