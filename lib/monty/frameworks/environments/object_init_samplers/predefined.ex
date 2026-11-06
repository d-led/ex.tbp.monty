defmodule Monty.Frameworks.Environments.ObjectInitSamplers.Predefined do
  @moduledoc """
  The poses a config wrote down, one per episode or one per epoch.

  Mirrors `frameworks/environments/object_init_samplers.py::Predefined`. Monty's
  default rotations are `[(0, 0, 0), (45, 0, 0)]`, so an experiment that names
  no poses still shows each object upright and then turned — which is the whole
  of how a training epoch of two objects sees one of them from two sides.

  ## Which pose an episode gets

  `mod_counter` is the episode when `change_every_episode` is set and the epoch
  otherwise, and each list is indexed `mod_counter mod length`. So a run of three
  epochs over two rotations is upright, turned, upright.

  ## Why this class decides what a run can learn

  A sampler that is never called leaves every episode of an experiment looking at
  the object in the same pose: the graph a first episode stores then explains
  every later one, the module recognises on the first matching step, and the
  memory never grows a second graph. That is not a matching defect — it is this
  class missing.
  """

  alias Monty.Frameworks.Environments.ObjectInitSamplers.Default

  @default_positions [[0.0, 1.5, 0.0]]
  @default_rotations [[0.0, 0.0, 0.0], [45.0, 0.0, 0.0]]

  defstruct positions: @default_positions,
            rotations: @default_rotations,
            scales: [[1.0, 1.0, 1.0]],
            change_every_episode: nil

  @type euler :: {number(), number(), number()} | [number()]
  @type t :: %__MODULE__{
          positions: [[number()]],
          rotations: [[number()]],
          scales: [[number()]],
          change_every_episode: boolean() | nil
        }

  @doc """
  The poses a config names.

  Options: `:positions`, `:rotations` (Euler angles in degrees) and `:scales`.
  An empty or absent list is Monty's default, which is what makes
  `object_init_sampler: {_target_: …Predefined}` with nothing else a run of two
  poses. A pose may be written as a tuple or a list; it is a list from here on,
  which is the shape a world is handed.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      positions: vectors(Keyword.get(options, :positions), @default_positions),
      rotations: vectors(Keyword.get(options, :rotations), @default_rotations),
      scales: vectors(Keyword.get(options, :scales), [[1.0, 1.0, 1.0]]),
      change_every_episode: Keyword.get(options, :change_every_episode)
    }
  end

  @doc "The parameters the episode's pose is built from."
  @spec call(t(), non_neg_integer(), Default.mode(), non_neg_integer(), non_neg_integer()) ::
          Default.params()
  def call(%__MODULE__{} = sampler, _seed, _mode, epoch, episode) do
    counter = if sampler.change_every_episode, do: episode, else: epoch

    Default.params(
      nth(sampler.rotations, counter),
      nth(sampler.positions, counter),
      nth(sampler.scales, counter)
    )
  end

  @doc "How many poses the sampler walks before repeating: Monty's `__len__`."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = sampler), do: length(all_combinations_of_params(sampler))

  @doc """
  Every combination of a rotation, a scale and a place.

  Monty's `all_combinations_of_params`: what a caller would walk if it wanted the
  sampler's poses as a set rather than as a cycle.
  """
  @spec all_combinations_of_params(t()) :: [%{optional(atom()) => list()}]
  def all_combinations_of_params(%__MODULE__{} = sampler) do
    for rotation <- sampler.rotations,
        scale <- sampler.scales,
        position <- sampler.positions do
      %{rotations: [rotation], scales: [scale], positions: [position]}
    end
  end

  defp nth(list, counter), do: Enum.at(list, rem(counter, length(list)))

  defp vectors(nil, default), do: default
  defp vectors([], default), do: default
  defp vectors(values, _default) when is_list(values), do: Enum.map(values, &Default.vector/1)
end
