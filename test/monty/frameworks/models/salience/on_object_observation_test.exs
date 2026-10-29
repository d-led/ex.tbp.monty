defmodule Monty.Frameworks.Models.Salience.OnObjectObservationTest do
  @moduledoc """
  A view, reshaped so a salience module can address it by pixel.

  The fixture is a three by three view whose middle pixel is off the object, in a
  patch whose outline is otherwise on it — which is the shape these tests need,
  because the difference between "the middle pixel" and "the on-object pixels" is
  the whole point of the reshaping.
  """

  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Models.Salience.OnObjectObservation
  alias Monty.Frameworks.Models.Salience.Strategies.Uniform

  # `[x, y, z, semantic_id]` per pixel, row by row: the fourth column is what the
  # depth-to-points transform leaves as the on-surface mask.
  defp observation(semantic_ids) do
    points =
      for {semantic_id, index} <- Enum.with_index(semantic_ids) do
        [index * 1.0, 0.0, -1.0, semantic_id]
      end

    %{
      "rgba" => List.duplicate(List.duplicate([1.0, 1.0, 1.0, 1.0], 3), 3),
      "depth" => List.duplicate(List.duplicate(1.0, 3), 3),
      "semantic_3d" => points
    }
  end

  defp all_on_object, do: observation(List.duplicate(1.0, 9))

  describe "the view as grids" do
    test "splits the flat point cloud into a location map and an on-object mask" do
      %OnObjectObservation{} = view = OnObjectObservation.from(all_on_object(), salience(9))

      assert length(view.location_map) == 3
      assert view.location_map |> hd() |> Enum.map(&hd/1) == [0.0, 1.0, 2.0]

      # The eighth pixel's x coordinate is 7: the mask and the locations are in
      # the same order, which is what lets a strategy index either.
      assert view.on_object_map |> List.flatten() |> Enum.all?()
      assert view.location_map |> Enum.at(2) |> Enum.at(2) |> hd() == 8.0
    end

    test "collects the on-object locations and their salience, and only those" do
      # The middle pixel is background: eight of nine pixels are on the object.
      view =
        OnObjectObservation.from(
          observation([1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0]),
          salience(9)
        )

      # The salience map numbers its pixels 1 to 9, row by row; the middle one
      # (5) is the pixel that is off the object, so it is the one left out.
      assert view.salience == [1.0, 2.0, 3.0, 4.0, 6.0, 7.0, 8.0, 9.0]
      assert length(view.locations) == 8
    end

    test "answers no centre location when the middle pixel is off the object" do
      # Which is what a surface agent far from its object sees, and the reason
      # the inhibitor is told `nil` rather than a made-up place.
      off_centre =
        OnObjectObservation.from(
          observation([1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0]),
          salience(9)
        )

      assert off_centre.centre_location == nil

      on_centre = OnObjectObservation.from(all_on_object(), salience(9))
      assert on_centre.centre_location == [4.0, 0.0, -1.0]
    end
  end

  describe "the uniform strategy" do
    test "finds every pixel equally interesting, whatever it was shown" do
      rgba = List.duplicate(List.duplicate([0.2, 0.4, 0.6, 1.0], 2), 2)
      depth = [[0.1, 0.5], [2.0, 0.05]]

      assert Uniform.call(Uniform.new(), Context.new(0), rgba, depth) == [
               [1.0, 1.0],
               [1.0, 1.0]
             ]
    end
  end

  defp salience(count) do
    count
    |> then(&Enum.map(1..&1, fn index -> index * 1.0 end))
    |> Enum.chunk_every(3)
  end
end
