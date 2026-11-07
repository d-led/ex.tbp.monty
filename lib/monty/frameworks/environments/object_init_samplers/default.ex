defmodule Monty.Frameworks.Environments.ObjectInitSamplers.Default do
  @moduledoc """
  Where an object stands, and how it is turned, in one episode.

  Mirrors `frameworks/environments/object_init_samplers.py::Default`: a random
  orientation about all three axes and a random place along x, drawn from a
  generator seeded with the episode's own seed — so the same run repeats and two
  episodes of it differ.

  ## The draw is numpy's

  `np.random.RandomState(seed)` is what Monty draws from, and
  `Monty.Random.Numpy` is that generator, so the three angles and the place are
  the numbers Monty would have got, not merely numbers from the same
  distribution. The seed is `episode_seed/3` of the run's seed, the mode and the
  episode.

  ## What an episode is given

  A map, in Monty's own names: `"position"` in metres, `"rotation"` as a `wxyz`
  quaternion, `"euler_rotation"` in degrees, and `"scale"`. Monty's
  `Predefined` and `RandomRotation` write `quat_rotation` beside `rotation` —
  the same quaternion under a second name — and this module does not, which is
  Monty's own asymmetry; a supervision that reads it asks for it with
  `with_quat_rotation/1`.
  """

  alias Monty.Frameworks.Experiments.Seed
  alias Monty.Geometry.Rotation
  alias Monty.Math
  alias Monty.Random.Numpy

  @type mode :: :train | :eval
  @type params :: %{optional(String.t()) => term()}

  @doc "A rotation about every axis, and a place within half a metre of the middle."
  @spec call(non_neg_integer(), mode(), non_neg_integer(), non_neg_integer()) :: params()
  def call(seed, mode, _epoch, episode) do
    rng = Numpy.new(Seed.episode_seed(seed, mode, episode))

    {angles, rng} = angles(rng)
    {x, _rng} = Numpy.uniform(rng, -0.5, 0.5)

    params(angles, [x, 0.0, 0.0], Math.ones_vector())
  end

  @doc """
  Three angles in degrees, drawn one at a time.

  Separate draws, not one draw scaled: `np.random.uniform(0, 360, 3)` consumes
  three values of the stream, and a caller that drew one and multiplied it would
  be reading a different generator.
  """
  @spec angles(Numpy.t()) :: {[float()], Numpy.t()}
  def angles(rng) do
    {rx, rng} = Numpy.uniform(rng, 0.0, 360.0)
    {ry, rng} = Numpy.uniform(rng, 0.0, 360.0)
    {rz, rng} = Numpy.uniform(rng, 0.0, 360.0)

    {[rx, ry, rz], rng}
  end

  @doc "The parameters an object is added with, from Euler angles in degrees."
  @spec params([number()], [number()] | tuple(), [number()] | tuple()) :: params()
  def params([_rx, _ry, _rz] = euler, position, scale) do
    {:ok, rotation} = Rotation.from_euler_degrees(euler)

    %{
      "position" => vector(position),
      "rotation" => rotation |> Rotation.to_quaternion() |> Tuple.to_list(),
      "euler_rotation" => vector(euler),
      "scale" => vector(scale)
    }
  end

  @doc """
  The same parameters, with the object's turn under its second name.

  `quat_rotation` is the `wxyz` quaternion `rotation` already holds, under the
  name Monty's pretraining supervision reads (`Monty.Frameworks.Models.
  GraphMatching.GraphLM.supervise/3`). The samplers that carry it upstream carry
  it here; `Default` does not, and neither does this.
  """
  @spec with_quat_rotation(params()) :: params()
  def with_quat_rotation(%{"rotation" => quaternion} = params),
    do: Map.put(params, "quat_rotation", quaternion)

  @doc """
  A place, an orientation or a scale as three floats.

  Monty writes them as tuples and the port's own helpers do too, so both shapes
  arrive here and both leave as the list a world is handed.
  """
  @spec vector(term()) :: [float()]
  def vector({x, y, z}), do: [x * 1.0, y * 1.0, z * 1.0]
  def vector([x, y, z]), do: [x * 1.0, y * 1.0, z * 1.0]
end
