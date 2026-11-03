defmodule ExTbpMonty.ReleaseTest do
  # The prerequisites are addressed by environment variables, which are the
  # machine's, so nothing else in the suite may run while this one sets them.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Release
  alias Monty.Prerequisites

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
  # belongs, so `present?/1` answers yes and the step has nothing to fetch.
  defp plant(prerequisite) do
    if prerequisite[:extract] do
      File.mkdir_p!(Prerequisites.where_it_lands(prerequisite))
    else
      path = Prerequisites.target_path(prerequisite)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
    end
  end

  # Monty's own variables, pointed at a directory of this test's own and put back
  # afterwards — a run in another test must not read this one's tree.
  defp in_data_root(root, fun) do
    variables = [
      {"MONTY_DATA", Path.join(root, "data")},
      {"MONTY_MODELS", Path.join(root, "models")},
      {"MONTY_LOGS", Path.join(root, "logs")}
    ]

    previous = Enum.map(variables, fn {name, _} -> {name, System.get_env(name)} end)

    Enum.each(variables, fn {name, value} ->
      File.mkdir_p!(value)
      System.put_env(name, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
