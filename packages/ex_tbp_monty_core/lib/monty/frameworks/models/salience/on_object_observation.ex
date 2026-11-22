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
    centre_index = div(rows, 2) * columns + div(columns, 2)

    {location_map, on_object_map, locations, salience, centre} =
      walk(points, salience_map, centre_index)

    %__MODULE__{
      centre_location: centre,
      locations: locations,
      salience: salience,
      on_object_map: on_object_map,
      location_map: location_map
    }
  end

  # One walk over the flat point cloud builds everything this view carries: each
  # pixel's place, the on-object mask, and — for the pixels that are on the
  # object — its place and its salience again, in Monty's order. A row of the
  # salience map ends exactly where a row of the point cloud does, so the walk
  # takes its row boundaries from the salience map and puts each finished row
  # onto its grid as it finishes. The centre is the pixel the flat index names,
  # so one walk answers it too instead of a second look at a grid.
  #
  # Building the two grids apart from the walk — `Enum.map` then
  # `Enum.chunk_every`, twice, then a third pass to collect the on-object
  # pixels — was four traversals of four thousand pixels a step, and the
  # traversals were most of this module's cost.
  defp walk([], _salience_map, _centre_index), do: {[], [], [], [], nil}

  defp walk(points, [row | values], centre_index) do
    {_locations, _mask, location_rows, mask_rows, on_locations, on_salience, _index, centre} =
      raster(points, values, row, {[], [], [], [], [], [], 0, nil}, centre_index)

    {Enum.reverse(location_rows), Enum.reverse(mask_rows), Enum.reverse(on_locations),
     Enum.reverse(on_salience), centre}
  end

  defp raster([], _values, _row, acc, _centre_index), do: finish_row(acc)

  defp raster(points, values, [], acc, centre_index) do
    [row | values] = values
    raster(points, values, row, finish_row(acc), centre_index)
  end

  defp raster([point | points], values, [value | row], acc, centre_index) do
    raster(points, values, row, pixel(point, value, acc, centre_index), centre_index)
  end

  # `[x, y, z, semantic_id]`: the place, whether it is on the object, and how
  # interesting the view found the pixel.
  defp pixel(
         [x, y, z, semantic_id],
         value,
         {locations, mask, location_rows, mask_rows, on_locations, on_salience, index, centre},
         centre_index
       ) do
    location = [x, y, z]
    on_object? = semantic_id > 0.0

    centre =
      if index == centre_index and on_object?,
        do: location,
        else: centre

    if on_object? do
      {[location | locations], [true | mask], location_rows, mask_rows,
       [location | on_locations], [value | on_salience], index + 1, centre}
    else
      {[location | locations], [false | mask], location_rows, mask_rows, on_locations,
       on_salience, index + 1, centre}
    end
  end

  defp finish_row({locations, mask, location_rows, mask_rows, on_locations, on_salience, index, centre}) do
    {[], [], [Enum.reverse(locations) | location_rows], [Enum.reverse(mask) | mask_rows],
     on_locations, on_salience, index, centre}
  end

  # The image the observation was taken through: its rows and columns are the
  # grid every other array is reshaped to.
  defp shape(observation) do
    rgb = Map.fetch!(observation, "rgba")
    {length(rgb), rgb |> hd() |> length()}
  end
end
