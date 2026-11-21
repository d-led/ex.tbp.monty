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

  test "a picture kept without its depths says it is the recorded one" do
    # A replay draws the file a step wrote; the row does not carry the arrays
    # that would say how far the surface was, and a frame that plainly shows the
    # object must not claim the sensor saw nothing.
    frame =
      Camera.frame("patch", %{"images" => %{"depth" => "/runs/a/frames/6/patch-depth.png"}}, 6)

    assert frame.note == "step 6 · as recorded"
  end

  test "a sensor id is escaped, so a frame is markup a page may render" do
    frame = Camera.frame("<script>alert(1)</script>", observation(), 0)

    assert markup(frame) =~ "&lt;script&gt;"
    refute markup(frame) =~ "<script>"
  end

  test "the same percept draws the same picture" do
    assert Camera.frame("patch", observation(), 3) == Camera.frame("patch", observation(), 3)
  end

  test "a page's picture is the archive's picture, byte for byte" do
    # A run walks a step's pixels once and shows a page the bytes it archived. A
    # second walk of the same observation is what would let the two drift, so the
    # pictures a walk makes and the pictures made from its planes are one thing.
    walked = Camera.images(observation())

    assert Camera.pictures(Camera.planes(observation())) == walked
  end

  test "a depth image and a colour image of different sizes are each drawn at their own" do
    # A plane says how big it is, so a world whose two images disagree is drawn
    # rather than read past its short one — which is how a step's pictures stopped
    # a whole run's.
    planes =
      Camera.planes(%{"depth" => [[0.1, 0.2], [0.3, 0.4]], "rgba" => [[[1.0, 0.0, 0.0, 1.0]]]})

    pictures = Camera.pictures(planes)

    assert {planes.depth.width, planes.depth.height} == {2, 2}
    assert {planes.colour.width, planes.colour.height} == {1, 1}

    for picture <- [pictures.depth, pictures.colour] do
      assert <<137, 80, 78, 71, _rest::binary>> = Base.decode64!(picture)
    end
  end

  test "a recorded step's pictures are not re-encoded" do
    # A replay hands over the names the run filed its pictures under, not the
    # numbers behind them; there is nothing left to walk and nothing to replace.
    recorded = %{
      "images" => %{
        "depth" => "0-1-depth.png",
        "colour" => "0-1-colour.png",
        "range" => [0.02, 0.04]
      }
    }

    assert Camera.pictures(Camera.planes(recorded)) ==
             %{depth: nil, colour: nil, range: nil}
  end

  test "a picture's numbers are read in the range its own camera used" do
    # Monty's observations, and a MuJoCo camera, carry `rgba` as `0..255`; the
    # stand-in scene paints floats in `0..1`. Scaling a byte a second time does
    # not make a wrong colour, it makes a term that is not iodata at all — which
    # is how a recorded MuJoCo run died on its first frame.
    bytes = %{"depth" => [[0.5]], "rgba" => [[[181, 164, 146, 255]]]}
    assert Camera.planes(bytes).colour.pixels == <<181, 164, 146>>

    painted = %{"depth" => [[0.5]], "rgba" => [[[1.0, 1.0, 1.0, 1.0]]]}
    assert Camera.planes(painted).colour.pixels == <<255, 255, 255>>
  end

  test "a camera that hands its colours back as floats in 0..255 is not scaled twice" do
    # The same range, said with floats instead of integers: a MuJoCo render does
    # this, and `220.0` scaled a second time is 56 100 — not a byte, and not
    # iodata, which took the writer that archives a run's pictures down with it.
    floats = %{"depth" => [[0.5]], "rgba" => [[[220.0, 190.0, 12.0, 1.0]]]}

    assert Camera.planes(floats).colour.pixels == <<220, 190, 12>>
  end

  test "a channel outside 0..255 is clamped into a byte rather than raising" do
    # Whatever a camera says, what leaves here is bytes: a picture is never the
    # reason a process stops.
    wild = %{"depth" => [[0.5]], "rgba" => [[[56_100, -4.0, 300, 255]]]}

    assert Camera.planes(wild).colour.pixels == <<255, 0, 255>>
  end

  defp markup(frame), do: Phoenix.HTML.safe_to_string(frame.data)
end
