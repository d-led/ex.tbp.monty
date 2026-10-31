defmodule Monty.Studio.DraftsTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Blueprint
  alias Monty.Studio.Drafts
  alias Monty.Test.Tmp

  setup do
    {:ok, dir: Tmp.env_dir("drafts-test", :experiments_dir)}
  end

  describe "a draft's file" do
    test "is a YAML file directly under the drafts directory", %{dir: dir} do
      assert Drafts.path("mustard") == Path.join(dir, "mustard.yaml")
    end

    test "cannot be given a name that climbs out of the directory" do
      for name <- ["../../etc/passwd", "sub/draft", "..", "", "with space", "a\\b"] do
        assert_raise ArgumentError, ~r/not a draft name/, fn -> Drafts.path(name) end
      end
    end

    test "is refused the same way for reading and deleting", %{dir: dir} do
      File.write!(Path.join(dir, "kept.yaml"), "kept: true\n")

      assert_raise ArgumentError, fn -> Drafts.read("../kept") end
      assert_raise ArgumentError, fn -> Drafts.delete("../kept") end
    end

    test "a name that cannot be a draft is not a draft, rather than an error" do
      refute Drafts.exists?("tutorial/first_experiment")
      refute Drafts.exists?("")
    end
  end

  describe "what a draft leaves on disk" do
    test "saving writes the experiment file it was given", %{dir: dir} do
      blueprint = Blueprint.new(%{"name" => "one_of_each", "base" => "tutorial/first_experiment"})

      assert {:ok, path} = Drafts.save(blueprint)
      assert path == Path.join(dir, "one_of_each.yaml")
      assert Drafts.names() == ["one_of_each"]
    end
  end

  describe "exporting an experiment as a file" do
    test "a draft is its own file, as it was saved", %{dir: dir} do
      File.write!(Path.join(dir, "kept.yaml"), "kept: true\n")

      assert {:ok, exported} = Drafts.export("kept")

      assert exported.source == :draft
      assert exported.filename == "kept.yaml"
      assert exported.yaml == "kept: true\n"
    end

    test "Monty's own experiment is exported from its config tree, not composed", %{
      dir: dir
    } do
      File.mkdir_p!(dir)

      assert {:ok, exported} = Drafts.export("tutorial/first_experiment")

      assert exported.source == :monty
      # The short file a person edits: its defaults list, not the composed tree.
      assert exported.yaml =~ "defaults:"
      assert exported.filename == "tutorial_first_experiment.yaml"
    end

    test "a name that is not an experiment reaches nothing" do
      assert {:error, message} = Drafts.export("../../secrets")
      assert message =~ "neither a draft nor an experiment"
    end
  end

  describe "importing an experiment file" do
    test "keeps it as a draft, composed first", %{dir: dir} do
      {:ok, exported} = Drafts.export("tutorial/first_experiment")

      assert {:ok, imported} = Drafts.import("imported_experiment", exported.yaml)

      assert imported.name == "imported_experiment"
      assert File.read!(Path.join(dir, "imported_experiment.yaml")) == exported.yaml
      assert Drafts.exists?("imported_experiment")
    end

    test "refuses a file that is not a Hydra config" do
      assert {:error, _reason} = Drafts.import("broken", "not: {a hydra config")
      refute Drafts.exists?("broken")
    end

    test "does not overwrite a draft unless told to" do
      {:ok, exported} = Drafts.export("tutorial/first_experiment")
      {:ok, _imported} = Drafts.import("twice", exported.yaml)

      assert {:error, message} = Drafts.import("twice", exported.yaml)
      assert message =~ "already here"

      assert {:ok, _replaced} = Drafts.import("twice", exported.yaml, overwrite: true)
    end

    test "a name from a file elsewhere is not a name for a draft" do
      {:ok, exported} = Drafts.export("tutorial/first_experiment")

      assert {:error, message} = Drafts.import("tutorial/first_experiment", exported.yaml)
      assert message =~ "Rename the file"
    end
  end
end
