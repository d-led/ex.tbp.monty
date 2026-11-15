defmodule Monty.Simulators.ExMujoco.SimulatorDecodeTest do
  use ExUnit.Case, async: true

  alias Monty.Simulators.ExMujoco.Simulator

  # What a pass's bytes mean, apart from the machine that drew them: these cases
  # run where there is no OpenGL, which is where the world's own cases skip, and
  # they are why the decoding is its own function.
  describe "a pass's bytes" do
    test "rgba is the camera's three channels with the alpha the camera does not send" do
      assert Simulator.rows(<<1, 2, 3, 4, 5, 6>>, 2, :rgba) == [[[1, 2, 3, 255], [4, 5, 6, 255]]]
    end

    test "depth is metres, one float32 a pixel, in rows" do
      binary = for v <- [0.25, 0.5], into: <<>>, do: <<v::float-32-little>>

      assert Simulator.rows(binary, 2, :depth) == [[0.25, 0.5]]
    end

    test "segmentation is Monty's own ids, so MuJoCo's background becomes 0" do
      binary = for id <- [-1, 7], into: <<>>, do: <<id::signed-32-little>>

      assert Simulator.rows(binary, 2, {:semantic, %{-1 => 0, 7 => 42}}) == [[0, 42]]
    end

    test "an id the scene did not name keeps MuJoCo's own number" do
      binary = <<9::signed-32-little>>

      assert Simulator.rows(binary, 1, {:semantic, %{-1 => 0}}) == [[9]]
    end
  end

  describe "what a sensor asks for" do
    test "a sensor that wants ids is asked for three passes, and one that does not for two" do
      assert Simulator.passes(%{"semantic" => true}) == [:rgb, :depth, :segmentation]
      assert Simulator.passes(%{"semantic" => false}) == [:rgb, :depth]
      assert Simulator.passes(%{}) == [:rgb, :depth]
    end

    test "a sensor that names no resolution is drawn at the protocol's own" do
      assert Simulator.resolution(%{}) == {64, 64}
      assert Simulator.resolution(%{"height" => 32, "width" => 48}) == {32, 48}
    end
  end

  test "the passes a renderer answered become the names a model looks for" do
    rgb = for _ <- 1..2, into: <<>>, do: <<10, 20, 30>>
    depth = for v <- [1.0, 2.0], into: <<>>, do: <<v::float-32-little>>
    segmentation = for id <- [-1, 7], into: <<>>, do: <<id::signed-32-little>>

    decoded =
      Simulator.decode([:rgb, :depth, :segmentation], [rgb, depth, segmentation], {1, 2}, %{
        -1 => 0,
        7 => 42
      })

    assert decoded == %{
             "rgba" => [[[10, 20, 30, 255], [10, 20, 30, 255]]],
             "depth" => [[1.0, 2.0]],
             "semantic" => [[0, 42]]
           }
  end
end
