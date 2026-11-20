defmodule Monty.Experiment.Environment.OmniglotInterface do
  @moduledoc """
  Which character an episode is about, and what it is called.

  Mirrors `tbp/monty/experiment/environment.py::OmniglotInterface`. A config names
  three parallel lists — `alphabets`, `characters`, `versions` — one entry per
  episode, and the interface addresses the world with all three: alphabet 0,
  character 1, version 1 is the first drawing of the first character of the first
  alphabet.

  A character is named by its alphabet's directory and its number, joined with an
  underscore (`Alphabet_of_the_Magi_1`), because that is what a log can be read
  against and what a memory is keyed by. Its pose is fixed: a drawing is presented
  flat and upright at the origin, so there is no rotation, no scale and no position
  to report.

  The world is threaded through rather than held, as everywhere in this port: an
  interface is a value, and `change_object_by_idx/3` answers the value it became
  together with the world it switched.
  """

  alias Monty.Frameworks.Environments.TwoDData.OmniglotEnvironment

  @enforce_keys [:alphabets, :characters, :versions]
  defstruct alphabets: [],
            characters: [],
            versions: [],
            object_names: [],
            current_object: 0,
            n_objects: 0,
            episodes: 0,
            epochs: 0,
            primary_target: nil,
            positioning_procedures: []

  @type t :: %__MODULE__{
          alphabets: [non_neg_integer()],
          characters: [pos_integer()],
          versions: [pos_integer()],
          object_names: [String.t()],
          current_object: non_neg_integer(),
          n_objects: non_neg_integer(),
          episodes: non_neg_integer(),
          epochs: non_neg_integer(),
          primary_target: map() | nil,
          positioning_procedures: list()
        }

  @typedoc "The world this interface switches between characters of."
  @type environment :: OmniglotEnvironment.t()

  @doc """
  The interface over a config's alphabets, characters and versions.

  Options: `:alphabets`, `:characters`, `:versions` (one entry per episode, in the
  same order) and `:object_names` — the world's alphabet directories, in the order
  the world sorted them, which is what a character is named from.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    alphabets = Keyword.fetch!(options, :alphabets)
    characters = Keyword.fetch!(options, :characters)
    versions = Keyword.fetch!(options, :versions)
    alphabet_names = Keyword.get(options, :object_names, [])

    %__MODULE__{
      alphabets: alphabets,
      characters: characters,
      versions: versions,
      object_names: names(alphabets, characters, alphabet_names),
      n_objects: length(characters),
      positioning_procedures: Keyword.get(options, :positioning_procedures, [])
    }
  end

  defp names(alphabets, characters, alphabet_names) do
    for {alphabet, character} <- Enum.zip(alphabets, characters) do
      OmniglotEnvironment.character_name(Enum.at(alphabet_names, alphabet), character)
    end
  end

  @doc "How many episodes the config describes: one per character."
  @spec n_versions(t()) :: non_neg_integer()
  def n_versions(%__MODULE__{n_objects: n_objects}), do: n_objects

  @doc "The character the interface is on: which alphabet, which of its characters."
  @spec character(t()) :: {non_neg_integer(), pos_integer(), pos_integer()}
  def character(%__MODULE__{} = interface) do
    {Enum.at(interface.alphabets, interface.current_object),
     Enum.at(interface.characters, interface.current_object),
     Enum.at(interface.versions, interface.current_object)}
  end

  @doc """
  The episode after this one: the next character is loaded into the world.

  Monty advances a counter and wraps at the end, so a config with six characters
  runs six episodes and then starts over.
  """
  @spec post_episode(t(), environment()) :: {:ok, t(), environment()} | {:error, String.t()}
  def post_episode(%__MODULE__{} = interface, environment) do
    next = rem(interface.current_object + 1, interface.n_objects)

    with {:ok, interface, environment} <- change_object_by_idx(interface, next, environment) do
      {:ok, %{interface | episodes: interface.episodes + 1}, environment}
    end
  end

  @doc "An epoch ends by counting, as Monty's does."
  @spec post_epoch(t()) :: t()
  def post_epoch(%__MODULE__{} = interface), do: %{interface | epochs: interface.epochs + 1}

  @doc """
  Makes the character at `index` the episode's target, and loads it.

  An index outside the config's characters is refused with Monty's own message: an
  experiment asking for a character it does not have is a configuration mistake,
  not a state to recover from.
  """
  @spec change_object_by_idx(t(), integer(), environment()) ::
          {:ok, t(), environment()} | {:error, String.t()}
  def change_object_by_idx(%__MODULE__{} = interface, index, environment) do
    if index < 0 or index >= interface.n_objects do
      {:error, "idx must satisfy 0 <= idx < #{interface.n_objects}, got #{index}"}
    else
      interface = %{
        interface
        | current_object: index,
          primary_target: primary_target(interface, index)
      }

      {alphabet, character, version} = character(interface)

      {:ok, interface,
       OmniglotEnvironment.switch_to_object(environment, alphabet, character, version)}
    end
  end

  defp primary_target(interface, index) do
    # Monty's own values for a drawing: it lies flat and upright at the origin, so
    # the target has no rotation, no scale and no position of its own.
    %{
      "object_name" => Enum.at(interface.object_names, index),
      "euler_rotation" => [0.0, 0.0, 0.0],
      "position" => [0.0, 0.0, 0.0],
      "rotation" => [1.0, 0.0, 0.0, 0.0],
      "scale" => [1.0, 1.0, 1.0]
    }
  end
end
