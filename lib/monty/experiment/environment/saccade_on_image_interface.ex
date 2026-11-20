defmodule Monty.Experiment.Environment.SaccadeOnImageInterface do
  @moduledoc """
  Which capture an episode is about, and which one comes next.

  Mirrors `tbp/monty/experiment/environment.py::SaccadeOnImageInterface`. The
  image world has no objects to add or remove — a capture *is* the scene — so
  this interface is the cycle and the name: a config lists `scenes` and
  `versions`, `versions` has one entry per episode, and each episode switches the
  world to `(scenes[episode], versions[episode])` in turn.

  The world is threaded through rather than held, as everywhere in this port: an
  interface is a value, and `change_object_by_idx/3` answers the value it became
  together with the world it switched.

  Monty's `PrimaryTarget` here is a fixed pose at the origin — every capture is
  already centred on its object — and the object's name is the scene directory's
  name with the index Monty sorts by removed: `0_numenta_mug` is `numenta_mug`.
  There is no semantic sensor in this world, so no id is stamped on the object and
  the target has none.
  """

  alias Monty.Frameworks.Environments.TwoDData.SaccadeOnImageEnvironment

  @enforce_keys [:scenes, :versions]
  defstruct scenes: [],
            versions: [],
            object_names: [],
            current_scene_version: 0,
            episodes: 0,
            epochs: 0,
            primary_target: nil,
            positioning_procedures: []

  @type t :: %__MODULE__{
          scenes: [non_neg_integer()],
          versions: [non_neg_integer()],
          object_names: [String.t()],
          current_scene_version: non_neg_integer(),
          episodes: non_neg_integer(),
          epochs: non_neg_integer(),
          primary_target: map() | nil,
          positioning_procedures: list()
        }

  @typedoc "The image world this interface switches between captures of."
  @type environment :: SaccadeOnImageEnvironment.t()

  @doc """
  The interface over a config's scenes and versions.

  Options: `:scenes` and `:versions` (one version per episode), and
  `:object_names` — the world's scene directory names, in the order the world
  sorted them, which is what a target is named from.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      scenes: Keyword.fetch!(options, :scenes),
      versions: Keyword.fetch!(options, :versions),
      object_names: Keyword.get(options, :object_names, []),
      positioning_procedures: Keyword.get(options, :positioning_procedures, [])
    }
  end

  @doc "How many episodes the config describes: one per version."
  @spec n_versions(t()) :: non_neg_integer()
  def n_versions(%__MODULE__{versions: versions}), do: length(versions)

  @doc """
  The scene and version the interface is on.
  """
  @spec capture(t()) :: {non_neg_integer(), non_neg_integer()}
  def capture(%__MODULE__{} = interface) do
    {Enum.at(interface.scenes, interface.current_scene_version),
     Enum.at(interface.versions, interface.current_scene_version)}
  end

  @doc """
  The episode after this one: the next capture is loaded into the world.

  Monty advances a counter and wraps at the end, so a config with four versions
  runs four episodes and then starts over.
  """
  @spec post_episode(t(), environment()) :: {:ok, t(), environment()} | {:error, String.t()}
  def post_episode(%__MODULE__{} = interface, environment) do
    next = rem(interface.current_scene_version + 1, n_versions(interface))

    with {:ok, interface, environment} <- change_object_by_idx(interface, next, environment) do
      {:ok, %{interface | episodes: interface.episodes + 1}, environment}
    end
  end

  @doc "An epoch ends by counting, as Monty's does."
  @spec post_epoch(t()) :: t()
  def post_epoch(%__MODULE__{} = interface), do: %{interface | epochs: interface.epochs + 1}

  @doc """
  Makes the capture at `index` the episode's target, and loads it.

  An index outside the config's versions is refused with Monty's own message: an
  experiment asking for a capture it does not have is a configuration mistake,
  not a state to recover from.
  """
  @spec change_object_by_idx(t(), integer(), environment()) ::
          {:ok, t(), environment()} | {:error, String.t()}
  def change_object_by_idx(%__MODULE__{} = interface, index, environment) do
    if index < 0 or index >= n_versions(interface) do
      {:error, "idx must satisfy 0 <= idx < #{n_versions(interface)}, got #{index}"}
    else
      interface = %{
        interface
        | current_scene_version: index,
          primary_target: primary_target(interface, index)
      }

      {scene, version} = capture(interface)

      {:ok, interface, SaccadeOnImageEnvironment.switch_to_object(environment, scene, version)}
    end
  end

  @doc """
  The object a scene directory's capture is of: its name without the index.

  Monty sorts scenes by a leading number and strips it, so `0_numenta_mug` names
  the object `numenta_mug`.
  """
  @spec target_object_name(String.t()) :: String.t()
  def target_object_name(scene_name) do
    scene_name |> String.split("_") |> Enum.drop(1) |> Enum.join("_")
  end

  defp primary_target(interface, index) do
    name =
      interface.object_names
      |> Enum.at(Enum.at(interface.scenes, index), "")
      |> target_object_name()

    # Monty's own values for an image world: a capture is centred and upright, so
    # the target sits at the origin with no rotation and no scale.
    %{
      "object_name" => name,
      "euler_rotation" => [0.0, 0.0, 0.0],
      "position" => [0.0, 0.0, 0.0],
      "rotation" => [1.0, 0.0, 0.0, 0.0],
      "scale" => [1.0, 1.0, 1.0]
    }
  end
end
