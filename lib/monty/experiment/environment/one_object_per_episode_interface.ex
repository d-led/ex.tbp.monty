defmodule Monty.Experiment.Environment.OneObjectPerEpisodeInterface do
  @moduledoc """
  Which object an episode is about, and which id the world should stamp on it.

  Mirrors `tbp/monty/experiment/environment.py::OneObjectPerEpisodeInterface`.
  Monty's evaluation experiments show one *primary target* at a time, with an
  optional set of distractors around it, and everything from the semantic sensor to
  the positioning procedures needs to know which object that is — by name, and by
  the positive integer id the world stamps on its pixels.

  ## What it decides, and what it does not

  This is the decision half of Monty's class: the object list and its
  deduplication, the semantic mapping, which object comes next, what the primary
  target's parameters are, and which objects a distractor may be drawn from. The
  other half — adding and removing objects in a scene — is a scene's business, so
  the interface *asks* a scene to do it and the scene answers the id it gave the
  object. A scene that cannot add objects yet is a scene that has not been ported;
  the arithmetic above it is already Monty's.

  ## Where a guess used to be

  `Setup` used to say "the target is 1" and "there are no distractors". Both are
  this class's answers: the id is `semantic_label_to_id[name]`, and the count is
  the config's `num_distractors`. The stand-in world stamps its one object `1`,
  which is what Monty's mapping produces for a one-object experiment — now derived
  rather than assumed.

  ## The stream

  Distractor names are drawn from the source list, as Monty draws them, but from
  this port's stream rather than his (`docs/monty-bugs.md` §2.1), so which
  distractors appear is not comparable — the *candidates* are, and they are what
  the test checks.
  """

  @enforce_keys [:object_names]
  defstruct object_names: [],
            source_object_list: [],
            num_distractors: 0,
            semantic_label_to_id: %{},
            semantic_id_to_label: %{},
            object_init_sampler: nil,
            object_params: nil,
            current_object: 0,
            n_objects: 0,
            primary_target: nil,
            positioning_procedures: []

  @type object_name :: String.t()

  @type t :: %__MODULE__{
          object_names: [object_name()],
          source_object_list: [object_name()],
          num_distractors: non_neg_integer(),
          semantic_label_to_id: %{object_name() => pos_integer()},
          semantic_id_to_label: %{pos_integer() => object_name()},
          object_init_sampler: (integer(), atom(), integer(), integer() -> map()) | nil,
          object_params: map() | nil,
          current_object: non_neg_integer(),
          n_objects: non_neg_integer(),
          primary_target: map() | nil,
          positioning_procedures: list()
        }

  @doc """
  An interface over the objects a config names.

  `:object_names` is either a plain list — every object is a primary target in
  turn, and there are no distractors — or a map with `"targets_list"`,
  `"source_object_list"` and `"num_distractors"`, which is how Monty's multi-object
  experiments are configured.

  Options: `:object_init_sampler`, a function of `(seed, mode, epochs, episodes)`
  answering the object's parameters; `:positioning_procedures`, the factories the
  prologue will use.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    {names, source, distractors} = object_names(Keyword.fetch!(options, :object_names))
    {label_to_id, id_to_label} = semantic_mapping(source)

    interface = %__MODULE__{
      object_names: names,
      source_object_list: source,
      num_distractors: distractors,
      semantic_label_to_id: label_to_id,
      semantic_id_to_label: id_to_label,
      object_init_sampler: Keyword.get(options, :object_init_sampler),
      positioning_procedures: Keyword.get(options, :positioning_procedures, []),
      n_objects: length(names)
    }

    # Monty's constructor samples the object's parameters straight away, so an
    # interface that has not been told which object yet still knows where the
    # first one would go.
    sample_object(
      interface,
      Keyword.get(options, :seed, 0),
      Keyword.get(options, :mode, :eval),
      Keyword.get(options, :epochs, 0),
      Keyword.get(options, :episodes, 0)
    )
  end

  # Monty's two shapes, and its deduplication: the source list is the object list
  # with repeats dropped, in the order the names first appear.
  defp object_names(names) when is_list(names) do
    {names, uniq(names), 0}
  end

  defp object_names(%{} = names) do
    targets = Map.get(names, "targets_list") || []

    source =
      case Map.get(names, "source_object_list") do
        nil -> uniq(targets)
        list -> uniq(list)
      end

    {targets, source, Map.get(names, "num_distractors", 0)}
  end

  defp uniq(names),
    do:
      names
      |> Enum.reduce([], fn name, kept -> if name in kept, do: kept, else: kept ++ [name] end)

  # Monty starts at one so that an on-object id (> 0) is never confused with the
  # background's zero.
  defp semantic_mapping(source) do
    source
    |> Enum.with_index(1)
    |> Enum.reduce({%{}, %{}}, fn {label, id}, {label_to_id, id_to_label} ->
      {Map.put(label_to_id, label, id), Map.put(id_to_label, id, label)}
    end)
  end

  @doc "The object an episode is about, as the config names it."
  @spec object_name(t()) :: object_name() | nil
  def object_name(%__MODULE__{primary_target: %{"object" => name}}), do: name
  def object_name(%__MODULE__{}), do: nil

  @doc """
  The semantic id the world should stamp on the episode's object.

  `nil` until an object has been chosen — Monty's `primary_target` starts unset,
  and so does this.
  """
  @spec target_semantic_id(t()) :: pos_integer() | nil
  def target_semantic_id(%__MODULE__{primary_target: %{"semantic_id" => id}}), do: id
  def target_semantic_id(%__MODULE__{}), do: nil

  @doc """
  The object episode `episode` is about, without a scene to ask.

  Monty's interface advances one object per episode by removing every object and
  adding the next one, and past the end of the list it starts again. A run here
  is one episode and starts a fresh interface, so the cycle is arithmetic rather
  than state: `rem(episode, n)` names the object `cycle_object/2` would have
  reached after `episode` episodes.
  """
  @spec object_for(t(), non_neg_integer()) :: object_name() | nil
  def object_for(%__MODULE__{n_objects: 0}, _episode), do: nil

  def object_for(%__MODULE__{} = interface, episode) do
    Enum.at(interface.object_names, rem(episode, interface.n_objects))
  end

  @doc """
  Which object comes next: past the end of the list is the beginning again.
  """
  @spec cycle_object(t(), scene) :: {:ok, t(), scene} | {:error, term()}
        when scene: term()
  def cycle_object(%__MODULE__{} = interface, scene) do
    change_object_by_idx(interface, rem(interface.current_object + 1, interface.n_objects), scene)
  end

  @typedoc "A scene the interface can ask to change what it holds."
  @type scene :: term()

  @doc """
  Makes the object at `index` the episode's primary target.

  Monty removes every object from the scene, adds the target with the semantic id
  its label maps to, adds distractors if the config asks for any, and records what
  it did in `primary_target`. The scene answers the id it gave the object it added.

  An index outside the list is refused with Monty's own message: an experiment
  asking for an object it does not have is a configuration mistake, not a state to
  recover from.
  """
  @spec change_object_by_idx(t(), integer(), scene) :: {:ok, t(), scene} | {:error, term()}
  def change_object_by_idx(%__MODULE__{} = interface, index, scene) do
    if index < 0 or index >= interface.n_objects do
      {:error, "idx must satisfy 0 <= idx < #{interface.n_objects}, got #{index}"}
    else
      name = Enum.at(interface.object_names, index)
      id = Map.fetch!(interface.semantic_label_to_id, name)
      params = interface.object_params || %{}

      scene = remove_all_objects(scene)

      {object_id, scene} =
        add_object(scene, Map.merge(%{"name" => name, "semantic_id" => id}, params))

      interface = %__MODULE__{
        interface
        | current_object: index,
          primary_target: Map.merge(%{"object" => name, "semantic_id" => id}, params)
      }

      with {:ok, interface} <- place_distractors(interface, object_id) do
        {:ok, interface, scene}
      end
    end
  end

  # Monty draws distractors from the source list and adds them around the target.
  # The stand-in world holds one object, so rather than pretend it placed them —
  # and let an evaluation believe it was measuring against distractors it never
  # had — the interface says it cannot (`docs/monty-bugs.md` §2.16).
  defp place_distractors(%__MODULE__{num_distractors: 0} = interface, _object_id),
    do: {:ok, interface}

  defp place_distractors(%__MODULE__{num_distractors: count}, _object_id),
    do: {:error, {:distractors_not_supported, count}}

  @doc """
  The objects a distractor may be drawn from.

  Everything in the source list but the primary target, which is Monty's rule and
  its reason: an evaluation asks how well the model stays on the object it was
  asked about, so a distractor with the same name would make the question
  ambiguous.
  """
  @spec distractor_candidates(t(), object_name()) :: [object_name()]
  def distractor_candidates(%__MODULE__{} = interface, primary_target_name) do
    Enum.reject(interface.source_object_list, &(&1 == primary_target_name))
  end

  @doc """
  The parameters an object is placed with, asked of the config's sampler.

  Monty calls the sampler on every episode; a port that placed objects without it
  would be running a different experiment.
  """
  @spec sample_object(t(), integer(), atom(), integer(), integer()) :: t()
  def sample_object(
        %__MODULE__{object_init_sampler: nil} = interface,
        _seed,
        _mode,
        _epochs,
        _episodes
      ),
      do: interface

  def sample_object(%__MODULE__{} = interface, seed, mode, epochs, episodes) do
    %{interface | object_params: interface.object_init_sampler.(seed, mode, epochs, episodes)}
  end

  # A scene is either a function that takes the request, or a struct whose module
  # knows how to take it — the same two shapes the environment interface steps.
  defp remove_all_objects(scene) when is_function(scene, 1), do: scene.(:remove_all_objects)
  defp remove_all_objects(scene), do: scene.__struct__.remove_all_objects(scene)

  defp add_object(scene, attributes) when is_function(scene, 1),
    do: scene.({:add_object, attributes})

  defp add_object(scene, attributes), do: scene.__struct__.add_object(scene, attributes)
end
