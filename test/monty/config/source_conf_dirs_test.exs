defmodule Monty.Config.SourceConfDirsTest do
  @moduledoc """
  The order our configs are composed in, and the one thing a refresh may not
  touch.

  `mix monty.inputs` mirrors Monty's `conf/` and `snapshots/` into `priv/monty`
  and deletes every other YAML under those prefixes (`Inputs.sync/2`'s prune). A
  config written inside the mirror survives until the next refresh and then
  vanishes without a message — so our tree is a sibling, and these tests keep it
  one. `source_overlay_test.exs` holds the other half, that a list of roots
  *is* an overlay when a file is read.
  """

  use ExUnit.Case, async: true

  alias Monty.Config.{Inputs, Source}

  describe "the roots a config is composed from" do
    test "are the experiment sets, then the group files they share, then Monty's copy" do
      roots = Source.conf_dirs()
      shared = Path.join(Source.extra_root(), "conf")

      assert List.last(roots) == Source.conf_dir()
      assert Enum.find_index(roots, &(&1 == shared)) == length(Source.extra_conf_dirs()) - 1

      # Every set comes before the shared tree, which is what lets a set replace
      # a group file of either without touching anything shared.
      for set <- Source.extra_conf_dirs() |> Enum.reject(&(&1 == shared)) do
        assert Enum.find_index(roots, &(&1 == set)) < Enum.find_index(roots, &(&1 == shared))
      end
    end

    test "hold the experiments of the sets this tree carries" do
      assert "dogs/surf_unsupervised" in Source.experiments(Source.conf_dirs())
    end

    test "find a set added later, with no code to change" do
      set = Path.join(System.tmp_dir!(), "set-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(set) end)
      File.mkdir_p!(Path.join(set, "experiment/somewhere"))
      File.write!(Path.join(set, "experiment/somewhere/first.yaml"), "defaults: []\n")

      assert "somewhere/first" in Source.experiments([set | Source.conf_dirs()])
    end

    test "are all outside the copy a refresh mirrors" do
      # Monty's own tree *is* the mirror — that is what a refresh writes. Ours
      # sit beside it, where the prune cannot reach them.
      assert Source.extra_root() != Source.inputs_root()

      for root <- [Source.extra_root() | Source.extra_conf_dirs()] do
        refute String.starts_with?(root, Source.inputs_root() <> "/"),
               "#{root} is inside the mirror, where `mix monty.inputs` prunes"
      end
    end
  end

  describe "a refresh of Monty's tree" do
    test "deletes its own stale configs and leaves ours alone" do
      mirror = Path.join(System.tmp_dir!(), "mirror-#{System.unique_integer([:positive])}")
      monty = Path.join(System.tmp_dir!(), "monty-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!([mirror, monty]) end)

      # A checkout: one experiment, the snapshots directory a refresh requires,
      # and the licence it copies by reading.
      File.mkdir_p!(Path.join(monty, "src/tbp/monty/conf/experiment"))
      File.write!(Path.join(monty, "src/tbp/monty/conf/experiment/kept.yaml"), "defaults: []\n")
      File.mkdir_p!(Path.join(monty, "tests/conf/snapshots"))
      File.write!(Path.join(monty, "LICENSE"), "MIT\n")

      # A mirror that already holds a config Monty no longer has.
      File.mkdir_p!(Path.join(mirror, "conf/experiment"))
      File.write!(Path.join(mirror, "conf/experiment/gone.yaml"), "defaults: []\n")

      # One of ours, in a set, named like something a prune would want.
      mine = Path.join(Source.extra_root(), "sets/dogs/conf/experiment/ours_probe.yaml")
      File.mkdir_p!(Path.dirname(mine))
      File.write!(mine, "defaults: []\n")
      on_exit(fn -> File.rm(mine) end)

      Inputs.sync(monty, mirror)

      refute File.exists?(Path.join(mirror, "conf/experiment/gone.yaml"))
      assert File.exists?(Path.join(mirror, "conf/experiment/kept.yaml"))
      assert File.exists?(mine)
    end
  end
end
