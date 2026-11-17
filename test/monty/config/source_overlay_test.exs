defmodule Monty.Config.SourceOverlayTest do
  use ExUnit.Case, async: true

  alias Monty.Config.Source
  alias Monty.Test.Tmp

  setup do
    ours = Tmp.dir("source-overlay-ours")
    montys = Tmp.dir("source-overlay-montys")

    File.mkdir_p!(Path.join([ours, "experiment", "dogs"]))
    File.write!(Path.join([ours, "experiment", "dogs", "supervised.yaml"]), "from: ours\n")
    File.mkdir_p!(Path.join([montys, "experiment"]))
    File.write!(Path.join([montys, "experiment", "supervised.yaml"]), "from: montys\n")
    File.write!(Path.join([montys, "experiment", "base.yaml"]), "from: montys\n")

    {:ok, ours: ours, montys: montys}
  end

  describe "one tree, or several" do
    test "a file present in both is answered by the first root", %{ours: ours, montys: montys} do
      assert {:ok, config} = Source.load([ours, montys], "experiment", "dogs/supervised")
      assert config.body == %{"from" => "ours"}
      assert config.file == Path.join([ours, "experiment", "dogs", "supervised.yaml"])
    end

    test "a file only the second root holds is still found", %{ours: ours, montys: montys} do
      assert {:ok, config} = Source.load([ours, montys], "experiment", "base")
      assert config.body == %{"from" => "montys"}
    end

    test "the experiments are both trees' names, once each", %{ours: ours, montys: montys} do
      assert Source.experiments([ours, montys]) == ["base", "dogs/supervised", "supervised"]
    end

    test "a group neither root holds is named by the first root's path", %{
      ours: ours,
      montys: montys
    } do
      path = Source.path_for([ours, montys], "environment", "nowhere")
      assert path == Path.join([ours, "environment", "nowhere.yaml"])

      assert {:error, {:cannot_read, ^path, :enoent}} =
               Source.load([ours, montys], "environment", "nowhere")
    end

    test "a single root is still one root", %{montys: montys} do
      assert Source.path_for(montys, "experiment", "base") ==
               Path.join([montys, "experiment", "base.yaml"])

      assert Source.roots(montys) == [montys]
    end
  end
end
