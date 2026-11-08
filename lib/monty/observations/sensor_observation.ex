defmodule Monty.Observations.SensorObservation do
  @moduledoc """
  What a sensor module hands a learning module, or an edge detector: one view of
  the world.

  Mirrors `tbp/monty/observations.py::SensorObservation`, which Python spells as
  a `TypedDict` with every field optional — a sensor sends what it can, and a
  learning module reads the keys it understands. A map would be the closest
  literal translation; this is a struct because it is *the* shape passed between
  modules and a struct is what every other message in this port is, so a wrong
  key is a compile-time fact rather than a `nil` found at run time.

  The fields are the ones Monty names, with the units its comments give:

    * `rgba` — the patch as rows of `[r, g, b, a]`, `0..255`.
    * `depth` — one distance per pixel, in metres.
    * `semantic` / `semantic_3d` — object ids and their 3-D points, when the
      simulator provides them.
    * `sensor_frame_data` — the sensor's own frame for the observation.
    * `cam_to_world` — the 4×4 transform from camera to world coordinates.
    * `pixel_loc` — where in the image the patch was taken, when it was cropped.
    * `raw` — the untouched image, for logging.
  """

  @enforce_keys [:rgba, :depth, :cam_to_world]
  defstruct rgba: nil,
            depth: nil,
            semantic: nil,
            semantic_3d: nil,
            sensor_frame_data: nil,
            cam_to_world: nil,
            pixel_loc: nil,
            raw: nil

  @type pixel :: [0..255]
  @type rows :: [[pixel()]]
  @type t :: %__MODULE__{
          rgba: rows(),
          depth: [[float()]],
          semantic: rows() | nil,
          semantic_3d: rows() | nil,
          sensor_frame_data: [float()] | nil,
          cam_to_world: [[float()]],
          pixel_loc: [number()] | nil,
          raw: term()
        }

  @doc """
  An observation, with the three fields every edge detector needs.

  `:rgba`, `:depth` and `:cam_to_world` are required because a detector reads
  all three — colour for the edge, depth for whether the edge is a crease in the
  world, and the transform to say which way the edge points.
  """
  @spec new(keyword()) :: t()
  def new(attributes) do
    struct!(__MODULE__, attributes)
  end
end
