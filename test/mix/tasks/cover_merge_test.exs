defmodule Mix.Tasks.Cover.MergeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cover.Merge
  alias Monty.Test.Tmp

  describe "input_files/1" do
    test "every partition's export is an input, and the merge's own output is not" do
      exports = ["cover/2.coverdata", "cover/1.coverdata", "cover/default.coverdata"]

      assert Merge.input_files(exports) == ["cover/1.coverdata", "cover/2.coverdata"]
    end
  end

  describe "merge/2" do
    test "nothing to merge is an error, and leaves no file behind" do
      output = Path.join(Tmp.dir("cover_merge"), "default.coverdata")

      assert {:error, reason} = Merge.merge([], output)
      assert reason =~ "no coverage exports to merge"
      refute File.exists?(output)
    end

    test "an export that cannot be read is named, and nothing is exported" do
      output = Path.join(Tmp.dir("cover_merge"), "default.coverdata")

      assert {:error, reason} = Merge.merge(["cover/does-not-exist.coverdata"], output)
      assert reason =~ "could not import cover/does-not-exist.coverdata"
      refute File.exists?(output)
    end
  end
end
