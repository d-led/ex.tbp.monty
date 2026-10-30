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

  describe "what the modules believed" do
    test "is recorded with the step, in the shape the database will hand back" do
      entry = RunLog.entry(info(), %{lm_0: belief()})

      # String keys all the way down, because that is what the JSON column
      # returns. A page replaying a recorded run and a page watching a live one
      # then read one shape, and `line/1` prints one line.
      assert %{
               "possible_matches" => ["mug"],
               "mlh" => %{"graph_id" => "mug", "evidence" => 3.0},
               "graphs" => %{"mug" => %{"max_evidence" => 3.0}}
             } = entry["beliefs"]["lm_0"]

      assert Jason.encode!(entry) |> Jason.decode!() == entry
    end

    test "and left out entirely when there is nothing to record" do
      refute Map.has_key?(RunLog.entry(info()), "beliefs")
    end

    test "a line says which object a module believes, how strongly, and how crowded" do
      line = info() |> RunLog.entry(%{lm_0: belief()}) |> RunLog.line()

      assert line =~ "lm_0: mug ev 3.0 (3 hyps, 1 possible)"
    end

    test "and prints the same line after the trip through the database" do
      entry = info() |> RunLog.entry(%{lm_0: belief()})
      stored = entry |> Jason.encode!() |> Jason.decode!()

      assert RunLog.line(stored) == RunLog.line(entry)
    end

    test "and says so plainly before it has seen anything" do
      line =
        info()
        |> RunLog.entry(%{lm_0: %{belief() | mlh: nil}})
        |> RunLog.line()

      assert line =~ "lm_0: nothing yet"
    end
  end

  defp info do
    %{
      step: 3,
      percept_ids: [:patch],
      inputs: %{lm_0: 1},
      votes: %{sent: 1, used: 1},
      goals: 1,
      actions: [],
      duration_us: 1234
    }
  end

  defp belief do
    %{
      possible_matches: ["mug"],
      mlh: %{
        graph_id: "mug",
        id: 0,
        location: [0.1, 0.0, 0.0],
        rotation_wxyz: [1.0, 0.0, 0.0, 0.0],
        evidence: 3.0
      },
      graphs: %{
        "mug" => %{
          hypotheses: 3,
          max_evidence: 3.0,
          within_x_percent: 2,
          top_evidence: [3.0, 2.9, 2.0]
        }
      },
      x_percent_threshold: 20,
      terminal_state: nil,
      detected_object: nil
    }
  end
end
