defmodule Monty.Frameworks.Environments.ObjectInitSamplers.RandomRotation do
  @moduledoc """
  One place, a new orientation every episode.

  Mirrors `frameworks/environments/object_init_samplers.py::RandomRotation`: the
  place and the scale are fixed when the sampler is built, and the orientation is
  drawn per episode from the episode's own seed — the same generator and the same
  numbers as `Default`, which this class specialises.

  An experiment that holds its object in one place and turns it is what this is
  for; `Default` also moves it.
  """

  alias Monty.Frameworks.Environments.ObjectInitSamplers.Default
  alias Monty.Math

  defstruct position: {0.0, 1.5, 0.0}, scale: Math.ones_vector()

  @type t :: %__MODULE__{position: tuple(), scale: tuple()}

  @doc "Where the object stands, and how big it is; the orientation is drawn per episode."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      position: Keyword.get(options, :position, {0.0, 1.5, 0.0}),
      scale: Keyword.get(options, :scale, Math.ones_vector())
    }
  end

  @doc "A random orientation about every axis, at the sampler's place."
  @spec call(t(), non_neg_integer(), Default.mode(), non_neg_integer(), non_neg_integer()) ::
          Default.params()
  def call(%__MODULE__{} = sampler, seed, mode, _epoch, episode) do
    rng =
      Monty.Random.Numpy.new(Monty.Frameworks.Experiments.Seed.episode_seed(seed, mode, episode))

    {angles, _rng} = Default.angles(rng)

    Default.params(angles, Tuple.to_list(sampler.position), Tuple.to_list(sampler.scale))
    |> Default.with_quat_rotation()
  end
end
