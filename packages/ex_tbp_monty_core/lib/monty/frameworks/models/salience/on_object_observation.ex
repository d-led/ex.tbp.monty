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

    {locations, salience} = on_object(on_object_map, location_map, salience_map)

    %__MODULE__{
      centre_location:
        if(Enum.at(Enum.at(on_object_map, half_row), half_column),
          do: Enum.at(Enum.at(location_map, half_row), half_column)
        ),
      locations: locations,
      salience: salience,
      on_object_map: on_object_map,
      location_map: location_map
    }
  end

  # Every on-object pixel's place and its salience, taken in the same walk as
  # the mask that decides which pixels are on the object. Reading them out by
  # index instead — `locations[row][column]` per pixel, which is how the point
  # cloud reads in numpy — walks to the row and then to the column for every one
  # of them: a thousand on-object pixels in a 64×64 view looked up their place
  # eighteen hundred times a step, and the walks were most of this module's cost.
  #
  # The three grids are walked together, a row at a time: `Enum.zip/1` would put
  # the same walk through a tuple per pixel first, and a view has four thousand.
  defp on_object(mask, location_map, salience_map),
    do: on_object(mask, location_map, salience_map, [], [])

  defp on_object([], [], [], locations, salience),
    do: {Enum.reverse(locations), Enum.reverse(salience)}

  defp on_object([mask_row | mask], [location_row | rows], [value_row | values], locations, salience) do
    {locations, salience} = on_object_row(mask_row, location_row, value_row, locations, salience)
    on_object(mask, rows, values, locations, salience)
  end

  defp on_object_row([], [], [], locations, salience), do: {locations, salience}

  defp on_object_row([true | mask], [location | rows], [value | values], locations, salience),
    do: on_object_row(mask, rows, values, [location | locations], [value | salience])

  defp on_object_row([_background | mask], [_location | rows], [_value | values], locations, salience),
    do: on_object_row(mask, rows, values, locations, salience)

  # The image the observation was taken through: its rows and columns are the
  # grid every other array is reshaped to.
  defp shape(observation) do
    rgb = Map.fetch!(observation, "rgba")
    {length(rgb), rgb |> hd() |> length()}
  end
end
