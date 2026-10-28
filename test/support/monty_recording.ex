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

  @default_learning_module "learning_module_0"

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
