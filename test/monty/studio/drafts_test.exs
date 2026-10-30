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
end
