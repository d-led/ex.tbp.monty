defmodule ExTbpMonty.BuildInfoTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.BuildInfo
  alias Monty.Test.Tmp

  @info %{
    version: "1.2.3",
    revision: "3f2a1c9d4e5f",
    built_at: "2026-10-27T12:00:00Z",
    ci: %{
      provider: "github",
      workflow: "ci",
      run_number: "42",
      run_url: "https://example.test/42"
    }
  }

  defp temp_dir, do: Tmp.dir("build_info")

  describe "write/2 and read/1" do
    test "a release reads back what its build was told" do
      dir = temp_dir()

      assert :ok = BuildInfo.write(dir, @info)
      assert BuildInfo.read(dir) == @info
    end

    test "a directory that was never built reports dev, not an empty version" do
      assert BuildInfo.read(temp_dir()) == %{
               version: "dev",
               revision: nil,
               built_at: nil,
               ci: nil
             }
    end

    test "a build outside a pipeline has no CI block" do
      dir = temp_dir()

      assert :ok = BuildInfo.write(dir, %{@info | ci: nil})
      assert BuildInfo.read(dir).ci == nil
    end
  end

  describe "label/1" do
    test "a checkout says dev" do
      assert BuildInfo.label(BuildInfo.dev()) == "dev"
    end

    test "a build with a commit says version plus the short commit" do
      assert BuildInfo.label(@info) == "1.2.3+3f2a1c9"
    end

    test "a build without a commit says the version alone" do
      assert BuildInfo.label(%{@info | revision: nil}) == "1.2.3"
    end
  end

  describe "ci_label/1" do
    test "names the run when there is one" do
      assert BuildInfo.ci_label(@info) == "ci #42"
    end

    test "names the workflow when there is no run number" do
      assert BuildInfo.ci_label(%{@info | ci: %{workflow: "ci", run_number: nil}}) == "ci"
    end

    test "is nil outside a pipeline" do
      assert BuildInfo.ci_label(%{@info | ci: nil}) == nil
    end
  end

  describe "description/1" do
    test "names what was built, from which commit, when, and by which run" do
      assert BuildInfo.description(@info) ==
               "version 1.2.3, commit 3f2a1c9, built 2026-10-27T12:00:00Z, https://example.test/42"
    end

    test "leaves out the parts a build did not know" do
      assert BuildInfo.description(BuildInfo.dev()) == "version dev"
    end
  end
end
