defmodule Monty.Frameworks.Models.Salience.OnObjectObservation do
  @moduledoc """
  A view, reshaped so that every array is addressed by pixel.

  Mirrors
  `tbp/monty/frameworks/models/salience/on_object_observation.py::OnObjectObservation`
  and its function of the same name. A raw observation arrives as an image and a
  flat list of points — one row per pixel, three coordinates and a semantic id —
  and a salience module wants them all as grids: where each pixel is in the
  world, which pixels are on the object, and how interesting those pixels are.
  That reshaping is this, once, rather than in each strategy.

  The middle pixel is the one `width * half + half` of the flat point cloud, as
  Monty indexes it: `location_map[row][column]` is the row the transform left for
  that pixel.

  ## Where the semantic mask comes from

  Monty reads the mask from the flat `semantic_3d` array's fourth column, not
  from the depth image, so a pixel that returned a depth but is not on an object
  counts as background — the difference that makes a surface agent's search look
  at its object rather than at the scenery.
  """

  @type location :: [float()]
  @type mask :: [[boolean()]]
  @type location_map :: [[location()]]

  defstruct centre_location: nil,
            locations: [],
            salience: [],
            on_object_map: [],
            location_map: []

  @type t :: %__MODULE__{
          centre_location: location() | nil,
          locations: [location()],
          salience: [float()],
          on_object_map: mask(),
          location_map: location_map()
        }

  @doc """
  The view's pixels, as grids: the on-object mask, the location map, and the
  on-object locations and salience values in the order Monty collects them —
  row by row, left to right.
  """
  @spec from(map(), [[float()]]) :: t()
  def from(observation, salience_map) do
    {rows, columns} = shape(observation)
    points = Map.fetch!(observation, "semantic_3d")

    location_map =
      points
      |> Enum.map(fn [x, y, z, _semantic_id] -> [x, y, z] end)
      |> Enum.chunk_every(columns)

    on_object_map =
      points
      |> Enum.map(fn [_x, _y, _z, semantic_id] -> semantic_id > 0.0 end)
      |> Enum.chunk_every(columns)

    half_row = div(rows, 2)
    half_column = div(columns, 2)

    on_object_pixels =
      for {row, row_index} <- Enum.with_index(on_object_map),
          {true, column_index} <- Enum.with_index(row),
          do: {row_index, column_index}

    %__MODULE__{
      centre_location:
        if(Enum.at(Enum.at(on_object_map, half_row), half_column),
          do: Enum.at(Enum.at(location_map, half_row), half_column)
        ),
      locations: Enum.map(on_object_pixels, &at(location_map, &1)),
      salience: Enum.map(on_object_pixels, &at(salience_map, &1)),
      on_object_map: on_object_map,
      location_map: location_map
    }
  end

  # The image the observation was taken through: its rows and columns are the
  # grid every other array is reshaped to.
  defp shape(observation) do
    rgb = Map.fetch!(observation, "rgba")
    {length(rgb), rgb |> hd() |> length()}
  end

  defp at(grid, {row, column}), do: grid |> Enum.at(row) |> Enum.at(column)
end
