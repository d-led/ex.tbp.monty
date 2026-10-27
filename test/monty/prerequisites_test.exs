defmodule Monty.PrerequisitesTest do
  use ExUnit.Case, async: false

  alias Monty.Prerequisites

  setup do
    previous = System.get_env("MONTY_MODELS")
    System.put_env("MONTY_MODELS", "/tmp/monty-models-test")

    on_exit(fn ->
      if previous,
        do: System.put_env("MONTY_MODELS", previous),
        else: System.delete_env("MONTY_MODELS")
    end)

    :ok
  end

  describe "the shipped manifest" do
    test "lists Monty's documented pretrained-model archives" do
      ids = Enum.map(Prerequisites.all(), & &1.id)

      assert "pretrained_ycb_v13" in ids
      assert "pretrained_ycb_v13_zip" in ids
    end
  end

  describe "target_path/1" do
    test "puts a prerequisite under the environment variable Monty uses" do
      prerequisite = Prerequisites.get("pretrained_ycb_v13")

      assert Prerequisites.target_path(prerequisite) ==
               "/tmp/monty-models-test/pretrained_ycb_v13.tgz"
    end

    test "refuses a root Monty does not define" do
      assert_raise ArgumentError, ~r/unknown prerequisite root/, fn ->
        Prerequisites.root_path("SOMEWHERE_ELSE")
      end
    end
  end

  describe "present?/1" do
    test "is false until the file exists" do
      entry = %{
        id: "absent",
        title: "Absent",
        url: "https://example.test/absent.tgz",
        root: "MONTY_MODELS",
        target: "does-not-exist.tgz",
        sha256: nil
      }

      refute Prerequisites.present?(entry)
    end
  end
end
