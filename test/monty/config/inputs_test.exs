defmodule Monty.Config.InputsTest do
  use ExUnit.Case, async: true

  alias Monty.Config.Inputs
  alias Monty.Test.Tmp

  setup do
    monty = Tmp.dir("monty-inputs-source")
    destination = Tmp.dir("monty-inputs-destination")

    yaml!(monty, "src/tbp/monty/conf/experiment/a.yaml", "a: 1\n")
    yaml!(monty, "src/tbp/monty/conf/monty/learning_module/evidence.yaml", "b: 2\n")
    File.write!(Path.join(monty, "src/tbp/monty/conf/update_snapshots.py"), "pass\n")
    yaml!(monty, "tests/conf/snapshots/top.yaml", "t: 1\n")
    yaml!(monty, "tests/conf/snapshots/tutorial/nested.yaml", "n: 1\n")
    File.write!(Path.join(monty, "LICENSE"), "Copyright 2025 Thousand Brains Project\n")

    {:ok,
     monty: monty, destination: destination, licence: "Copyright 2025 Thousand Brains Project\n"}
  end

  describe "copying Monty's inputs" do
    test "keeps Monty's shape, and takes nothing but YAML and the licence", context do
      assert {:ok, _summary} = Inputs.sync(context.monty, context.destination)

      assert File.read!(copied(context, "conf/experiment/a.yaml")) == "a: 1\n"

      assert File.read!(copied(context, "conf/monty/learning_module/evidence.yaml")) == "b: 2\n"

      # Nested snapshots are how Monty keeps the tutorial experiments, and they
      # are the ones a top-level-only glob used to miss.
      assert File.read!(copied(context, "snapshots/tutorial/nested.yaml")) == "n: 1\n"
      assert File.read!(copied(context, "LICENSE")) == context.licence

      refute File.exists?(copied(context, "conf/update_snapshots.py")),
             "Monty's own Hydra tooling is not a config"
    end

    test "a config Monty deleted is deleted here too", context do
      assert {:ok, _first} = Inputs.sync(context.monty, context.destination)
      File.rm!(Path.join([context.monty, "src", "tbp", "monty", "conf", "experiment", "a.yaml"]))

      assert {:ok, summary} = Inputs.sync(context.monty, context.destination)

      assert summary.removed == 1
      refute File.exists?(copied(context, "conf/experiment/a.yaml"))
    end

    test "says how much it changed, so a pull is reviewable by its numbers", context do
      assert {:ok, first} = Inputs.sync(context.monty, context.destination)
      assert first.added == 5
      assert first.updated == 0
      assert first.removed == 0
      assert first.conf_files == 2
      assert first.snapshot_files == 2

      assert {:ok, again} = Inputs.sync(context.monty, context.destination)
      assert {again.added, again.updated, again.removed} == {0, 0, 0}
    end

    test "records which commit the copy came from", context do
      assert {:ok, _summary} = Inputs.sync(context.monty, context.destination)

      manifest =
        context.destination |> Path.join("inputs.json") |> File.read!() |> Jason.decode!()

      # No `git` in a temporary directory, and that is a fact worth stating
      # rather than a crash: the copy is still the copy.
      assert manifest == %{"monty" => "unknown", "conf_files" => 2, "snapshot_files" => 2}
    end

    test "check says what it is, and writes nothing", context do
      assert {:ok, _summary} = Inputs.sync(context.monty, context.destination)
      assert {:ok, :current} = Inputs.check(context.monty, context.destination)

      File.write!(copied(context, "conf/experiment/a.yaml"), "a: 999\n")

      assert {:ok, {:stale, %{stale: 1, missing: 0, unexpected: 0}}} =
               Inputs.check(context.monty, context.destination)

      # Checking is a question, not a repair.
      assert File.read!(copied(context, "conf/experiment/a.yaml")) == "a: 999\n"
    end

    test "a checkout without Monty's config tree is named, not guessed at", context do
      File.rm_rf!(Path.join([context.monty, "src"]))

      assert {:error, {:missing, "config tree", dir}} =
               Inputs.sync(context.monty, context.destination)

      assert dir =~ "src/tbp/monty/conf"
    end
  end

  defp yaml!(root, relative, content) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp copied(context, relative), do: Path.join(context.destination, relative)
end
