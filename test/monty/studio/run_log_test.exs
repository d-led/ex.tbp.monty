defmodule Monty.Studio.RunLogTest do
  @moduledoc """
  What a run keeps of a timestep.

  A step is recorded twice: what the modules made of it, and what the sensors
  were looking at. The second is what a replay redraws from, so it has to carry
  a sensor's place and its report — and nothing whose size is the image's.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.RunLog

  describe "a recorded step" do
    test "keeps each sensor's place and what its centre reported" do
      moment = RunLog.moment(%{step: 2}, observations())

      assert moment["step"] == 2
      assert moment["sensors"]["patch"]["location"] == [0.0, 0.0, 0.1]
      assert moment["sensors"]["patch"]["principal_curvatures"] == [-20.0, -20.0]
    end

    test "and none of the camera's per-pixel arrays" do
      moment = RunLog.moment(%{step: 0}, observations())
      kept = moment["sensors"] |> Map.fetch!("patch") |> Map.keys() |> Enum.sort()

      assert kept == ["location", "pose_vectors", "principal_curvatures"]
    end
  end

  defp observations do
    %{
      "agent_id_0" => %{
        "patch" => %{
          "location" => [0.0, 0.0, 0.1],
          "principal_curvatures" => [-20.0, -20.0],
          "pose_vectors" => [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
          "depth" => [[0.05, 0.05], [0.05, 0.05]],
          "rgba" => [[[0.2, 0.7, 0.2, 1.0], [0.2, 0.7, 0.2, 1.0]]],
          "semantic" => [[1.0, 1.0], [1.0, 1.0]],
          "semantic_3d" => [[0.0, 0.0, 0.05, 1.0]],
          "sensor_frame_data" => [[0.0, 0.0, 0.05, 1.0]]
        }
      }
    }
  end
end
