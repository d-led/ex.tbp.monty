defmodule Monty.Studio.FramesTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Frames

  @agent "agent_id_0"

  defp observations(sensor_ids, step) do
    %{
      @agent =>
        Map.new(sensor_ids, fn sensor_id ->
          {sensor_id, %{"location" => [step * 0.01, 0.0, 0.1], "value" => step}}
        end)
    }
  end

  describe "the throttle" do
    test "the first frame for a sensor is always due" do
      assert Frames.due?(%{}, "patch", 1_000, 100)
    end

    test "a second frame waits for the throttle to pass" do
      sent = %{"patch" => 1_000}

      refute Frames.due?(sent, "patch", 1_050, 100)
      assert Frames.due?(sent, "patch", 1_100, 100)
    end

    test "sensors do not queue behind each other" do
      sent = %{"patch" => 1_000}

      assert Frames.due?(sent, "view_finder", 1_001, 100)
    end
  end

  describe "a step's frames" do
    test "one frame per sensor that is due" do
      {frames, sent} =
        Frames.for_step(
          ["patch", "view_finder"],
          observations(["patch", "view_finder"], 0),
          0,
          %{},
          1_000,
          100
        )

      assert Enum.map(frames, & &1.sensor_id) == ["patch", "view_finder"]
      assert sent == %{"patch" => 1_000, "view_finder" => 1_000}
    end

    test "a step inside the throttle sends nothing" do
      {frames, sent} =
        Frames.for_step(["patch"], observations(["patch"], 1), 1, %{"patch" => 1_000}, 1_010, 100)

      assert frames == []
      assert sent == %{"patch" => 1_000}
    end

    test "the picture moves when the percept moves" do
      # The frame is the image the world rendered, so a different image is a
      # different picture; the step number travels with it either way.
      near = %{
        @agent => %{"patch" => %{"depth" => [[0.02, 0.02]], "rgba" => [[[1.0, 0.0, 0.0, 1.0]]]}}
      }

      far = %{
        @agent => %{"patch" => %{"depth" => [[0.5, 0.5]], "rgba" => [[[0.0, 1.0, 0.0, 1.0]]]}}
      }

      {[first], _sent} = Frames.for_step(["patch"], near, 0, %{}, 1_000, 0)
      {[later], _sent} = Frames.for_step(["patch"], far, 10, %{}, 1_000, 0)

      assert first.data != later.data
      assert first.note =~ "flat at 0.020 m"
      assert later.note =~ "flat at 0.500 m"
    end

    test "a sensor with nothing to show gets no frame" do
      {frames, _sent} =
        Frames.for_step(["view_finder"], observations(["patch"], 0), 0, %{}, 1_000, 100)

      assert frames == []
    end

    test "observations for a bare sensor map work too, without the agent level" do
      bare = %{"patch" => %{"location" => [0.0, 0.0, 0.1]}}

      {[frame], _sent} = Frames.for_step(["patch"], bare, 0, %{}, 1_000, 100)

      assert frame.sensor_id == "patch"
    end
  end
end
