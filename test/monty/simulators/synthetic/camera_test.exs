defmodule Monty.Simulators.Synthetic.CameraTest do
  use ExUnit.Case, async: true

  alias Monty.Simulators.Synthetic.Camera

  describe "what a frame is" do
    test "a frame names its sensor and its step" do
      frame = Camera.frame("patch", %{"location" => [0.0, 0.0, 0.1]}, 7)

      assert frame.sensor_id == "patch"
      assert frame.step == 7
      assert frame.media_type == "image/svg+xml"
      assert frame.note =~ "step 7"
    end

    test "the view is deterministic: same percept, same picture" do
      observation = %{"location" => [0.02, 0.01, 0.1]}

      assert Camera.frame("patch", observation, 3) == Camera.frame("patch", observation, 3)
    end

    test "the object is drawn where the percept says it is" do
      {left, _y} = Camera.project([-0.5, 0.0, 0.1])
      {middle, _y} = Camera.project([0.0, 0.0, 0.1])
      {right, _y} = Camera.project([0.5, 0.0, 0.1])

      assert left < middle
      assert middle < right
    end

    test "a percept outside the view is clamped to the viewport" do
      {width, height} = Camera.size()

      assert {x, y} = Camera.project([99.0, -99.0, 0.1])
      assert x == width
      assert y == height
    end

    test "a sensor that reports no location still gets a frame" do
      frame = Camera.frame("view_finder", %{}, 0)

      assert frame.data =~ "<svg"
      assert frame.location == [0.0, 0.0, 0.0]
    end
  end
end
