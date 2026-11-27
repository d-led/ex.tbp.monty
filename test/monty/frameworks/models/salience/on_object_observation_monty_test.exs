defmodule Monty.Frameworks.Models.Salience.OnObjectObservationMontyTest do
  @moduledoc """
  Monty's own cases for `OnObjectObservation`, translated.

  Each test names the case in
  `tests/unit/frameworks/models/salience/on_object_observation_test.py` it
  translates. The view is the one Monty's own `create_data` builds: a 64 by 64
  observation whose object is the ten-by-ten block in the middle, a salience map
  that is 1 everywhere, and a place for every pixel that is `[row, column, 1]` —
  except the middle pixel, whose place is `[-1, -1, -1]`, so a case can tell a
  centre that was read from the observation from one that was not.

  `OnObjectObservation` keeps Monty's spelling of `centre`; the cases are about
  behaviour, so the struct's field is read as the port spells it.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.OnObjectObservation

  @size 64
  @centre 32
  @radius 5
  @sentinel [-1.0, -1.0, -1.0]

  defp on_object?(row, column, central_pixel_on_object, central_region_on_object) do
    inside =
      central_region_on_object and row >= @centre - @radius and row < @centre + @radius and
        column >= @centre - @radius and column < @centre + @radius

    inside and not (not central_pixel_on_object and row == @centre and column == @centre)
  end

  defp location(row, column) do
    if row == @centre and column == @centre, do: @sentinel, else: [row * 1.0, column * 1.0, 1.0]
  end

  # The raw observation Monty's create_data returns, and the salience map beside
  # it: one row per pixel, three coordinates and a semantic id.
  defp observation(central_pixel_on_object \\ true, central_region_on_object \\ true) do
    points =
      for row <- 0..(@size - 1), column <- 0..(@size - 1) do
        semantic_id =
          if on_object?(row, column, central_pixel_on_object, central_region_on_object),
            do: 1.0,
            else: 0.0

        location(row, column) ++ [semantic_id]
      end

    observation = %{
      "rgba" => List.duplicate(List.duplicate([0, 0, 0, 0], @size), @size),
      "semantic_3d" => points
    }

    salience_map = List.duplicate(List.duplicate(1.0, @size), @size)

    {observation, salience_map, central_pixel_on_object, central_region_on_object}
  end

  defp on_object_pixels(central_pixel_on_object, central_region_on_object) do
    for row <- 0..(@size - 1),
        column <- 0..(@size - 1),
        on_object?(row, column, central_pixel_on_object, central_region_on_object),
        do: {row, column}
  end

  # test_center_is_on_object_returns_with_center_location
  test "a centre that is on the object carries that pixel's place" do
    {observation, salience_map, _, _} = observation()

    assert OnObjectObservation.from(observation, salience_map).centre_location == @sentinel
  end

  # test_center_is_not_on_object_returns_none_center_location
  test "a centre that is not on the object carries no place" do
    {observation, salience_map, _, _} = observation(false)

    assert OnObjectObservation.from(observation, salience_map).centre_location == nil
  end

  # test_on_object_salience_and_locations_are_correct
  test "the on-object places and salience are the mask's, row by row" do
    {observation, salience_map, central_pixel_on_object, central_region_on_object} =
      observation()

    on_object = OnObjectObservation.from(observation, salience_map)

    pixels = on_object_pixels(central_pixel_on_object, central_region_on_object)

    assert on_object.locations == Enum.map(pixels, fn {row, column} -> location(row, column) end)
    assert on_object.salience == List.duplicate(1.0, length(pixels))
  end

  # test_on_object_salience_and_locations_are_empty_if_no_on_object
  test "a view with nothing on the object carries no places and no salience" do
    {observation, salience_map, _, _} = observation(true, false)

    on_object = OnObjectObservation.from(observation, salience_map)

    assert on_object.locations == []
    assert on_object.salience == []
  end

  # test_on_object_on_object_map_has_shape_of_input_image
  test "the on-object map is a grid the size of the view" do
    {observation, salience_map, _, _} = observation()

    on_object = OnObjectObservation.from(observation, salience_map)

    assert length(on_object.on_object_map) == @size
    assert Enum.all?(on_object.on_object_map, &(length(&1) == @size))
  end

  # test_on_object_location_map_has_shape_of_input_image
  test "the location map is a grid the size of the view, of three numbers a pixel" do
    {observation, salience_map, _, _} = observation()

    on_object = OnObjectObservation.from(observation, salience_map)

    assert length(on_object.location_map) == @size

    assert Enum.all?(on_object.location_map, fn row ->
             length(row) == @size and Enum.all?(row, &(length(&1) == 3))
           end)
  end
end
