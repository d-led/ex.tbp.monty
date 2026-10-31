defmodule Monty.Simulators.Synthetic.CameraTest do
  @moduledoc """
  What a sensor saw, as the page shows it.

  The claim is not "the markup looks like this" but "the frame carries the picture
  the world rendered, and says what can be read off it": two images, a depth range,
  and a frame that admits when there was nothing to see.
  """

  use ExUnit.Case, async: true

  alias Monty.Simulators.Synthetic.Camera

  # A 2 × 2 frame of a world that rendered something, with one pixel that saw
  # nothing — which is what a camera pointed past the object gives.
  defp observation do
    %{
      "location" => [0.0, 1.5, 0.1],
      "depth" => [[0.02, 0.03], [0.0, 0.04]],
      "rgba" => [
        [[0.2, 0.7, 0.2, 1.0], [0.2, 0.7, 0.2, 1.0]],
        [[0.0, 0.0, 0.0, 1.0], [0.2, 0.7, 0.2, 1.0]]
      ]
    }
  end

  test "a frame names its sensor and its step" do
    frame = Camera.frame("patch", observation(), 7)

    assert frame.sensor_id == "patch"
    assert frame.step == 7
    assert frame.location == [0.0, 1.5, 0.1]
  end

  test "the frame carries two images: the camera's and the depth" do
    markup = markup(Camera.frame("patch", observation(), 7))

    assert length(String.split(markup, "data:image/png;base64,")) - 1 == 2
    assert markup =~ ~s(alt="depth of patch")
    assert markup =~ ~s(alt="colour of patch")
  end

  test "the note says the depth range the picture was drawn over" do
    assert Camera.frame("patch", observation(), 7).note == "step 7 · depth 0.020–0.040 m"
  end

  test "depth is drawn dark for near and light for far, and nothing stays black" do
    {rows, range} = Camera.depth_view([[0.02, 0.03], [0.0, 0.04]])

    assert range == {0.02, 0.04}
    assert [near, middle] = Enum.at(rows, 0)
    assert [nothing, far] = Enum.at(rows, 1)

    assert near < middle
    assert middle < far
    assert nothing == 0
  end

  test "a depth image with one depth in it is drawn flat, and says so" do
    {rows, range} = Camera.depth_view([[0.05, 0.05]])

    assert range == {0.05, 0.05}
    assert rows == [[255, 255]]
  end

  test "a sensor whose world rendered nothing says so rather than showing an empty box" do
    frame = Camera.frame("patch", %{}, 0)

    assert markup(frame) =~ "no image from this sensor"
    assert frame.note == "step 0 · no image"
  end

  test "a sensor id is escaped, so a frame is markup a page may render" do
    frame = Camera.frame("<script>alert(1)</script>", observation(), 0)

    assert markup(frame) =~ "&lt;script&gt;"
    refute markup(frame) =~ "<script>"
  end

  test "the same percept draws the same picture" do
    assert Camera.frame("patch", observation(), 3) == Camera.frame("patch", observation(), 3)
  end

  defp markup(frame), do: Phoenix.HTML.safe_to_string(frame.data)
end
