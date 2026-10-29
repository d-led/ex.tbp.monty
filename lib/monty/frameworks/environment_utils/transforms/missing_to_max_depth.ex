defmodule Monty.Frameworks.EnvironmentUtils.Transforms.MissingToMaxDepth do
  @moduledoc """
  Depth where nothing was seen becomes "as far as the sensor can see".

  Mirrors `tbp/monty/frameworks/environment_utils/transforms.py::MissingToMaxDepth`.
  Habitat's depth sensor returns 0 where no mesh is present, and Monty's
  experiments replace that with `max_depth` before anything reads it — a surface
  agent's search asks whether the centre of its view is nearer than a metre, and
  a 0 there would be read as an object at zero distance.

  Everything at or below `:threshold` counts as missing, which is 0 by default.
  A sensor that already reports a far distance for the sky needs no transform at
  all, which is why this is a transform rather than part of a camera.
  """

  @behaviour Monty.Frameworks.EnvironmentUtils.Transforms.Transform

  @enforce_keys [:agent_id, :max_depth]
  defstruct agent_id: nil, max_depth: nil, threshold: 0.0

  @type t :: %__MODULE__{agent_id: atom() | String.t(), max_depth: float(), threshold: float()}

  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      agent_id: Keyword.fetch!(options, :agent_id),
      max_depth: Keyword.fetch!(options, :max_depth),
      threshold: Keyword.get(options, :threshold, 0.0)
    }
  end

  @doc """
  The transform a config describes.
  """
  @spec from_config(map()) :: t()
  def from_config(config) do
    new(
      agent_id: Map.fetch!(config, "agent_id"),
      max_depth: Map.fetch!(config, "max_depth"),
      threshold: Map.get(config, "threshold", 0.0)
    )
  end

  @impl true
  @spec call(map(), t(), Monty.Frameworks.EnvironmentUtils.Transforms.TransformContext.t()) ::
          map()
  def call(observations, %__MODULE__{} = transform, _ctx) do
    case Map.fetch(observations, transform.agent_id) do
      {:ok, sensors} -> Map.put(observations, transform.agent_id, transform(sensors, transform))
      :error -> observations
    end
  end

  defp transform(sensors, transform) do
    Map.new(sensors, fn {sensor_id, observation} ->
      {sensor_id, transform_observation(observation, transform)}
    end)
  end

  # A sensor with no depth image has nothing to replace, and is not given one.
  defp transform_observation(observation, transform) do
    case Map.fetch(observation, "depth") do
      {:ok, image} -> Map.put(observation, "depth", replace_missing(image, transform))
      :error -> observation
    end
  end

  defp replace_missing(image, transform) do
    Enum.map(image, fn row ->
      Enum.map(row, fn depth ->
        if depth <= transform.threshold, do: transform.max_depth, else: depth
      end)
    end)
  end
end
