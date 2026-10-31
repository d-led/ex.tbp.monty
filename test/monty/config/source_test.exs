defmodule Monty.Config.SourceTest do
  use ExUnit.Case, async: true

  alias Monty.Config.{SnapshotCheck, Source}

  describe "the Monty inputs this repository ships" do
    test "the config tree is here, and it is Monty's whole tree" do
      conf_dir = Source.conf_dir()

      assert File.dir?(conf_dir)
      assert Source.experiments(conf_dir) |> length() > 200

      # The groups an experiment is composed from, not only the experiments.
      for group <- ["monty", "environment", "termination", "logging"] do
        assert File.dir?(Path.join(conf_dir, group)), "#{group} is missing from the copy"
      end
    end

    test "the snapshots the composer is held to are here" do
      assert SnapshotCheck.names() |> length() > 50
    end

    test "the copy carries Monty's own licence, because the files are Monty's" do
      licence = Path.join(Source.inputs_root(), "LICENSE")

      # Not the exact wording: a copyright line is Monty's to change, and a test
      # that pins it fails on their commit rather than on ours.
      assert File.read!(licence) =~ ~r/Permission is hereby granted/i
      assert File.stat!(licence).size > 100
    end

    test "the manifest says where the copy came from, and agrees with what is here" do
      manifest =
        Source.inputs_root()
        |> Path.join("inputs.json")
        |> File.read!()
        |> Jason.decode!()

      assert manifest["monty"] != ""

      assert manifest["conf_files"] ==
               Source.conf_dir() |> Path.join("**/*.yaml") |> Path.wildcard() |> length()

      # The number the parity gate actually reads: every snapshot, nested or not.
      assert manifest["snapshot_files"] == length(SnapshotCheck.names())
    end
  end

  describe "a checkout is an alternative, not a requirement" do
    test "naming a checkout reaches its own config tree" do
      assert Source.conf_dir("/somewhere/monty") == "/somewhere/monty/src/tbp/monty/conf"
      assert Source.snapshots_dir("/somewhere/monty") == "/somewhere/monty/tests/conf/snapshots"
    end

    test "the shipped copy is what a plain call reads" do
      assert Source.conf_dir() == Path.join(Source.inputs_root(), "conf")
      assert Source.snapshots_dir() == Path.join(Source.inputs_root(), "snapshots")
    end
  end
end
