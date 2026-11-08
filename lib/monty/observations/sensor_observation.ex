defmodule Monty.Observations.SensorObservation do
  @moduledoc """
  One view of the world, as a sensor module receives it: Monty's
  `observations.py::SensorObservation`.

  Monty spells the shape as a `TypedDict` with every field optional, because a
  sensor sends what it can and a consumer reads the keys it understands. Here it
  is a map with string keys — the same shape the depth-to-3D transform writes and
  every consumer in this application reads — plus the names for the keys a
  consumer cannot do without:

    * `"rgba"` — the patch as rows of `[r, g, b, a]`, `0..255`.
    * `"depth"` — one distance per pixel, in metres.
    * `"semantic"` — one object id per pixel, `0` for background.
    * `"semantic_3d"` — one row per pixel, `[x, y, z, semantic_id]`, which is
      what a sensor module actually reads: the depth image is gone by then.
    * `"sensor_frame_data"` — the same points in the sensor's own frame.
    * `"cam_to_world"` — the 4x4 transform from camera to world coordinates.
    * `"pixel_loc"` — where in the image the patch was taken, when it was cropped.
    * `"raw"` — the untouched image, for logging.

  ## Why the accessors raise

  A missing `"semantic_3d"` is not an empty observation, it is an observation
  that never went through the depth-to-3D transform — and a filter that silently
  read `nil` there would report a surface at the origin. The accessors name the
  key they need, so the failure says which transform did not run.
  """

  @type pixel :: [0..255]
  @type rgba_rows :: [[pixel()]]
  @type float_rows :: [[float()]]
  @type point_row :: [number()]

  @type t :: %{optional(String.t()) => term()}

  @doc "The value under one of the observation's keys, or a sentence naming it."
  @spec fetch!(t(), String.t()) :: term()
  def fetch!(observation, key) do
    case Map.fetch(observation, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "the observation has no #{inspect(key)}; a sensor module reads it after the " <>
                "environment's transforms have run, and this one has not been through them"
    end
  end

  @doc "The patch, as rows of `[r, g, b, a]`."
  @spec rgba(t()) :: rgba_rows()
  def rgba(observation), do: fetch!(observation, "rgba")

  @doc "The depth image, one distance per pixel."
  @spec depth(t()) :: float_rows()
  def depth(observation), do: fetch!(observation, "depth")

  @doc "The transform from the camera's frame to the world's, as 4x4."
  @spec cam_to_world(t()) :: float_rows()
  def cam_to_world(observation), do: fetch!(observation, "cam_to_world")

  @doc """
  The patch's points in world coordinates, one `[x, y, z, semantic_id]` each.

  `{:error, :no_point_cloud}` when the observation never went through the
  transform, which is Monty's own answer to the same question.
  """
  @spec point_cloud(t()) :: {:ok, [point_row()]} | {:error, :no_point_cloud}
  def point_cloud(observation) do
    case Map.get(observation, "semantic_3d") do
      [_ | _] = points -> {:ok, points}
      _absent -> {:error, :no_point_cloud}
    end
  end

  @doc "The same observation with one key set, which is how a transform writes."
  @spec put(t(), String.t(), term()) :: t()
  def put(observation, key, value), do: Map.put(observation, key, value)
end
