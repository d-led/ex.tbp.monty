defmodule ExTbpMonty.ReleaseTest do
  # The prerequisites are addressed by environment variables, which are the
  # machine's, so nothing else in the suite may run while this one sets them.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Release
  alias Monty.Prerequisites
  alias Monty.Test.PrerequisiteRoots

  describe "the data a run reads, as a release step" do
    @tag :tmp_dir
    @tag timeout: 60_000
    test "fetches nothing when the volume already has every bundle", %{tmp_dir: tmp_dir} do
      in_data_root(tmp_dir, fn ->
        for prerequisite <- Prerequisites.all(), do: plant(prerequisite)

        assert Release.fetch_prerequisites() == :ok
      end)
    end

    @tag :tmp_dir
    @tag timeout: 60_000
    test "a download that does not arrive is an error, not a silent run", %{tmp_dir: tmp_dir} do
      in_data_root(tmp_dir, fn ->
        # Nothing listens on port 1, so this fails at once instead of hanging.
        refused = %{
          id: "refused",
          title: "a URL nothing answers",
          url: "http://127.0.0.1:1/nothing.tgz",
          root: "MONTY_DATA",
          target: "nothing.tgz",
          extract: true
        }

        assert {:error, _reason} = Prerequisites.fetch(refused)
      end)
    end
  end

  # One prerequisite as it looks after a first start: where the manifest says it
  # belongs. `PrerequisiteRoots` is the one place that knows what a fetched
  # bundle looks like, including that a directory holding nothing is not one.
  defp plant(prerequisite), do: PrerequisiteRoots.plant(prerequisite)

  # Monty's own variables, pointed at a directory of this test's own and put back
  # afterwards — a run in another test must not read this one's tree.
  defp in_data_root(root, fun), do: PrerequisiteRoots.with_roots(root, fun)
end
