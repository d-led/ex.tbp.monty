defmodule Monty.Test.MontyRecording do
  @moduledoc """
  A recording of what Monty showed its learning module, step by step.

  `scripts/record_monty_episode.py` runs a Monty experiment in Monty's own
  process and writes down every message the module was given and what it made of
  it. This reads one back as cortical messaging protocol messages, so a test can
  hand the Elixir implementation the same observations and hold it to the same
  answers.

  The recording keeps the steps on which the module was given something; the
  steps it was skipped on changed nothing it knows, so they are not replayed.
  """

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel

  @default_learning_module "learning_module_0"

  # What the evidence-based learning module matches on, which is the only part
  # of a pretrained model a graph is matched through.
  @pretrained_features [
    "hsv",
    "pose_vectors",
    "pose_fully_defined",
    "principal_curvatures_log"
  ]

  @doc """
  Loads a recording into one list of percepts per step.

  `:learning_module` picks the module's record when an experiment runs several;
  the default is the single module of a one-module run.
  """
  @spec load!(Path.t(), keyword()) :: [[Message.t()]]
  def load!(path, options \\ []) do
    module_id = Keyword.get(options, :learning_module, @default_learning_module)

    path
    |> File.stream!()
    |> Enum.map(&decode!/1)
    |> Enum.map(&steps_percepts(&1, module_id))
  end

  @doc """
  Every episode in a recording, each as per-step percepts.

  An episode is where `episode_step` stops increasing: Monty runs its episodes
  back to back in one process, so the recording is a single stream with the
  counter restarting. One experiment over ten objects is ten episodes, and each
  of them is a separate run here — which is the point of comparing them.
  """
  @spec episodes!(Path.t(), keyword()) :: [[[Message.t()]]]
  def episodes!(path, options \\ []) do
    module_id = Keyword.get(options, :learning_module, @default_learning_module)

    path
    |> File.stream!()
    |> Enum.map(&decode!/1)
    |> Enum.chunk_while(
      [],
      fn record, steps ->
        if steps != [] and record["episode_step"] <= hd(steps)["episode_step"] do
          {:cont, Enum.reverse(steps), [record]}
        else
          {:cont, [record | steps]}
        end
      end,
      fn steps -> {:cont, Enum.reverse(steps), []} end
    )
    |> Enum.map(fn episode -> Enum.map(episode, &steps_percepts(&1, module_id)) end)
  end

  @doc """
  The conclusion of every episode in a recording: what each episode's module
  answered at its last step.
  """
  @spec episode_conclusions!(Path.t(), keyword()) :: [map()]
  def episode_conclusions!(path, options \\ []) do
    module_id = Keyword.get(options, :learning_module, @default_learning_module)

    path
    |> File.stream!()
    |> Enum.map(&decode!/1)
    |> Enum.chunk_while(
      [],
      fn record, steps ->
        if steps != [] and record["episode_step"] <= hd(steps)["episode_step"] do
          {:cont, Enum.reverse(steps), [record]}
        else
          {:cont, [record | steps]}
        end
      end,
      fn steps -> {:cont, Enum.reverse(steps), []} end
    )
    |> Enum.map(fn episode ->
      episode |> List.last() |> get_in(["learning_modules", module_id, "state"])
    end)
  end

  @doc """
  The state Monty's module was in after its last step.

  What a recording is *compared against*: the conclusion, the object it named,
  and the most likely hypothesis.
  """
  @spec final_state!(Path.t(), keyword()) :: map()
  def final_state!(path, options \\ []) do
    module_id = Keyword.get(options, :learning_module, @default_learning_module)

    path
    |> File.stream!()
    |> Enum.map(&decode!/1)
    |> List.last()
    |> get_in(["learning_modules", module_id, "state"])
  end

  @doc """
  The most likely evidence per object after each step, as Monty recorded it.

  One map per step, `%{graph_id => evidence}` over the objects memory held, and
  `%{}` on the steps the module was not shown anything. Evidence is a sum of
  per-observation increments, so it is the number that tells whether two
  implementations are doing the same arithmetic, not merely reaching the same
  conclusion.
  """
  @spec evidence_over_steps!(Path.t(), keyword()) :: [%{optional(String.t()) => float()}]
  def evidence_over_steps!(path, options \\ []) do
    module_id = Keyword.get(options, :learning_module, @default_learning_module)

    path
    |> File.stream!()
    |> Enum.map(fn line ->
      line
      |> decode!()
      |> get_in(["learning_modules", module_id, "state", "graphs"])
      |> Kernel.||(%{})
      |> Map.new(fn {graph_id, graph} -> {graph_id, graph["max_evidence"]} end)
    end)
  end

  @doc """
  How many hypotheses Monty's module held per object after each step.

  The number says whether two implementations are carrying the same space of
  explanations — evidence can agree while the sets behind it do not.
  """
  @spec hypothesis_counts!(Path.t(), keyword()) :: [%{optional(String.t()) => non_neg_integer()}]
  def hypothesis_counts!(path, options \\ []) do
    module_id = Keyword.get(options, :learning_module, @default_learning_module)

    path
    |> File.stream!()
    |> Enum.map(fn line ->
      line
      |> decode!()
      |> get_in(["learning_modules", module_id, "state", "graphs"])
      |> Kernel.||(%{})
      |> Map.new(fn {graph_id, graph} -> {graph_id, graph["hypotheses"]} end)
    end)
  end

  @doc """
  How Monty's evidence was spread over each object's hypotheses after each step.

  `max_evidence` is what the port already reproduces. `hypotheses` and
  `within_x_percent` are the space behind it: how many explanations the module
  was carrying, and how many of them are close enough to the best one to be
  still possible. Two implementations can agree on the maximum and disagree on
  the set the pose test is given, and this is where that shows.
  """
  @spec graph_evidence!(Path.t(), keyword()) :: [
          %{
            optional(String.t()) => %{
              hypotheses: non_neg_integer(),
              max_evidence: float(),
              within_x_percent: non_neg_integer(),
              top_evidence: [float()]
            }
          }
        ]
  def graph_evidence!(path, options \\ []) do
    module_id = Keyword.get(options, :learning_module, @default_learning_module)

    path
    |> File.stream!()
    |> Enum.map(fn line ->
      line
      |> decode!()
      |> get_in(["learning_modules", module_id, "state", "graphs"])
      |> Kernel.||(%{})
    end)
  end

  @doc """
  What Monty's terminal condition saw after each step, and what it decided.

  An episode ends when one object is left *and* its pose is narrow enough to
  name: all possible poses inside `path_similarity_threshold` of their centre
  and inside `pose_similarity_threshold` of the most likely one, or enough
  consecutive steps of the same alternatives to call the object symmetric. These
  are the numbers behind that decision — the patience it counted, the two maxima
  it compared, and the verdict — so a reimplementation can be held to them and
  not only to the step the episode happened to end on.
  """
  @spec terminal_conditions!(Path.t(), keyword()) :: [
          %{
            optional(:symmetry) => non_neg_integer(),
            optional(:poses) => non_neg_integer(),
            optional(:spread) => float(),
            optional(:turn) => float(),
            optional(:unique) => boolean()
          }
          | nil
        ]
  def terminal_conditions!(path, options \\ []) do
    module_id = Keyword.get(options, :learning_module, @default_learning_module)

    path
    |> File.stream!()
    |> Enum.map(fn line ->
      state =
        line
        |> decode!()
        |> get_in(["learning_modules", module_id, "state"])

      case state do
        %{"unique_poses" => nil} ->
          nil

        %{"unique_poses" => unique} ->
          %{
            symmetry: state["symmetry_evidence"],
            poses: unique["poses"],
            spread: unique["spread"],
            turn: unique["turn"],
            unique: unique["unique"]
          }

        _without_unique_poses ->
          nil
      end
    end)
  end

  @doc """
  Loads a memory exported from Monty's pretrained models.

  `scripts/export_monty_pretrained.py` writes one object per line: its node
  positions and the features the learning module matches on. A model is those
  two things, so a memory is loaded rather than built — Monty keeps pretrained
  graphs exactly as they were stored, and so does this.
  """
  @spec load_pretrained!(Path.t(), keyword()) :: GraphMemory.t()
  def load_pretrained!(path, options \\ []) do
    features = Keyword.get(options, :features_to_use, @pretrained_features)
    channel = Keyword.get(options, :input_channel, "patch")
    wanted = Keyword.get(options, :objects)

    models =
      path
      |> File.read!()
      |> :zlib.gunzip()
      |> String.split("\n", trim: true)
      |> Enum.map(&decode!/1)
      |> Enum.filter(fn %{"object_id" => object_id} ->
        wanted == nil or object_id in wanted
      end)
      |> Map.new(fn %{"object_id" => object_id, "input_channel" => ^channel} = record ->
        {:ok, model} =
          object_id
          |> GraphObjectModel.new()
          |> GraphObjectModel.set_graph(graph_of(record))

        {object_id, %{channel => model}}
      end)

    GraphMemory.new(features_to_use: %{channel => features})
    |> GraphMemory.load_state_dict(models)
    |> GraphMemory.initialize_feature_arrays()
  end

  # A graph is positions and one row per node; the column order is this file's
  # own choice, so it is alphabetical and never assumed by anyone.
  defp graph_of(%{"positions" => positions, "features" => features}) do
    names = features |> Map.keys() |> Enum.sort()

    {mapping, _offset} =
      Enum.map_reduce(names, 0, fn name, offset ->
        width = features |> Map.fetch!(name) |> hd() |> length()
        {{name, {offset, offset + width}}, offset + width}
      end)

    %{
      pos: positions,
      x:
        names
        |> Enum.map(&Map.fetch!(features, &1))
        |> Enum.zip_with(&Enum.concat/1),
      feature_mapping: Map.new(mapping)
    }
  end

  defp decode!(line) do
    line |> String.trim() |> Jason.decode!()
  end

  defp steps_percepts(record, module_id) do
    record
    |> get_in(["learning_modules", module_id, "inputs"])
    |> Enum.map(&message!/1)
  end

  defp message!(input) do
    {:ok, message} =
      Message.new(
        location: input["location"],
        morphological_features: morphological_features(input["morphological_features"]),
        non_morphological_features: input["non_morphological_features"],
        confidence: input["confidence"],
        pass_message: input["pass_message"],
        process_features_in_lm: input["process_features_in_lm"],
        sender_id: input["sender_id"],
        sender_type: sender_type(input["sender_type"])
      )

    message
  end

  # The pose vectors arrive as the three rows Monty stores, in the three-row
  # form a message carries them in.
  defp morphological_features(features) do
    [normal, curvature_1, curvature_2] = Map.fetch!(features, "pose_vectors")

    features
    |> Map.take(["pose_fully_defined", "on_object"])
    |> Map.put(
      "pose_vectors",
      Monty.Geometry.SurfacePoseVectors.new(normal, curvature_1, curvature_2)
    )
  end

  defp sender_type("SM"), do: :sm
  defp sender_type("LM"), do: :lm
end
