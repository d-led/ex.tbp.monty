defmodule Monty.Frameworks.Utils.LoggingUtilsTest do
  @moduledoc """
  What a run does with what the last run left behind, and the target columns.

  The renames are the reason this module exists: three handlers write files into a
  run's directory, and a run whose file quietly grew the previous run's numbers
  would make every comparison after it a guess.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Utils.LoggingUtils
  alias Monty.Geometry.Rotation
  alias Monty.Test.Tmp

  setup do
    {:ok, dir: Tmp.dir("logging_utils")}
  end

  describe "a file that is already there" do
    test "is moved aside, with the extension kept", %{dir: dir} do
      path = Path.join(dir, "train_stats.csv")
      File.write!(path, "the last run\n")

      assert :ok = LoggingUtils.maybe_rename_existing_file(path)

      assert File.read!(Path.join(dir, "train_stats_old.csv")) == "the last run\n"
      refute File.exists?(path)
    end

    test "replaces an older _old rather than piling up", %{dir: dir} do
      path = Path.join(dir, "eval_stats.csv")
      File.write!(path, "this run\n")
      File.write!(Path.join(dir, "eval_stats_old.csv"), "two runs ago\n")

      assert :ok = LoggingUtils.maybe_rename_existing_file(path)

      assert File.read!(Path.join(dir, "eval_stats_old.csv")) == "this run\n"
    end

    test "and nothing is there is nothing to do", %{dir: dir} do
      assert :ok = LoggingUtils.maybe_rename_existing_file(Path.join(dir, "never_written.csv"))
    end
  end

  describe "a directory that is already there" do
    test "is moved aside whole", %{dir: dir} do
      path = Path.join(dir, "detailed_run_stats")
      File.mkdir_p!(path)
      File.write!(Path.join(path, "episode_000001.json"), "{}\n")

      assert :ok = LoggingUtils.maybe_rename_existing_dir(path)

      assert File.read!(Path.join([dir, "detailed_run_stats_old", "episode_000001.json"])) ==
               "{}\n"

      refute File.exists?(path)
    end

    test "replaces an older _old", %{dir: dir} do
      path = Path.join(dir, "wandb")
      File.mkdir_p!(path)
      File.mkdir_p!(Path.join(dir, "wandb_old"))
      File.write!(Path.join([dir, "wandb_old", "stale.txt"]), "older\n")

      assert :ok = LoggingUtils.maybe_rename_existing_dir(path)

      refute File.exists?(Path.join([dir, "wandb_old", "stale.txt"]))
    end

    test "that is a file is a reason, not a file quietly moved", %{dir: dir} do
      path = Path.join(dir, "wandb")
      File.write!(path, "not a directory\n")

      assert {:error, {:not_a_directory, ^path}} = LoggingUtils.maybe_rename_existing_dir(path)
    end
  end

  describe "a target" do
    test "is named the way a CSV column is" do
      target = %{
        "object" => "mug",
        "position" => [0.1, 0.2, 0.3],
        "euler_rotation" => [0.0, 45.0, 0.0],
        "rotation" => [0.0, 0.38, 0.0, 0.92],
        "scale" => [1.5, 1.5, 1.5]
      }

      assert LoggingUtils.target_data_to_dict(target) == %{
               "primary_target_object" => "mug",
               "primary_target_position" => [0.1, 0.2, 0.3],
               "primary_target_rotation_euler" => [0.0, 45.0, 0.0],
               "primary_target_rotation_quat" => [0.0, 0.38, 0.0, 0.92],
               "primary_target_scale" => 1.5
             }
    end

    test "records the pose it has and leaves the rest empty" do
      assert LoggingUtils.target_data_to_dict(%{"object" => "mug"}) == %{
               "primary_target_object" => "mug",
               "primary_target_position" => nil,
               "primary_target_rotation_euler" => nil,
               "primary_target_rotation_quat" => nil,
               "primary_target_scale" => nil
             }
    end
  end

  describe "the rotation error of a recognition" do
    test "is nothing when the pose is the one the object was placed with" do
      {:ok, mug} = Rotation.from_euler_degrees([0.0, 45.0, 0.0])

      assert LoggingUtils.compute_pose_error(mug, mug) == 0.0
    end

    test "is the angle between the two poses, in radians or degrees" do
      {:ok, turned} = Rotation.from_euler_degrees([0.0, 90.0, 0.0])

      assert_in_delta LoggingUtils.compute_pose_error(turned, Rotation.identity(), degrees: true),
                      90.0,
                      1.0e-6

      assert_in_delta LoggingUtils.compute_pose_error(turned, Rotation.identity()),
                      :math.pi() / 2,
                      1.0e-9
    end

    test "is the closest of the poses a symmetric object could be in" do
      {:ok, quarter} = Rotation.from_euler_degrees([0.0, 90.0, 0.0])
      identity = Rotation.identity()

      # A quarter turn is one of a symmetric object's equivalent poses, so a
      # recognition that chose it is not wrong.
      assert LoggingUtils.compute_pose_error([quarter, identity], identity) == 0.0
    end
  end
end
