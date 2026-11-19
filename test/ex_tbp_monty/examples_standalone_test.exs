defmodule ExTbpMonty.ExamplesStandaloneTest do
  # An example is what a person takes away: the two sample plugin nodes are
  # copied out of this repository, and a copy that reached back into it would be
  # a folder nobody can build. So each one asks Hex for what it needs, carries
  # the window its packaged app is, and is built from its own tree — the same
  # rule that made the shared `companion-window/` crate a mistake.
  use ExUnit.Case, async: true

  @examples Path.expand("../../examples", __DIR__)
  @packagers ~w(scripts/package.sh scripts/package.ps1)

  test "every example asks Hex, and nothing of ours by path" do
    for name <- example_names() do
      mix = read(name, "mix.exs")

      assert mix =~ ~r/^\s*defp deps do/m,
             "#{name}/mix.exs declares no deps, so the scan below proves nothing"

      refute mix =~ ~r/path:/,
             "#{name} takes a dependency by path; an example may only ask Hex"

      refute mix =~ ~r/:\s*ex_tbp_monty\b/,
             "#{name} depends on this application; an example is not a part of it"
    end
  end

  test "every example carries the window its packaged app runs" do
    for name <- example_names() do
      cargo = read(name, "app/Cargo.toml")

      assert cargo =~ ~r/^\[package\]/m, "#{name}/app is not a crate"
      assert read(name, "app/src/main.rs") =~ "fn main", "#{name}/app has no program"
      assert read(name, "app/ui/index.html") =~ "<html", "#{name}/app has no page"
    end
  end

  test "both packagers build each example's window from that example's own tree" do
    builds =
      for script <- @packagers, [manifest] <- manifests_in(script), do: {script, manifest}

    assert length(builds) == 2,
           "expected one window build per packager, found #{inspect(builds)}"

    for {script, manifest} <- builds do
      assert String.starts_with?(manifest, "examples/"),
             "#{script} builds #{manifest}, which is not an example's own app"
    end
  end

  defp manifests_in(script) do
    ~r/--manifest-path\s+"?([^"\s]+)/
    |> Regex.scan(File.read!(script), capture: :all_but_first)
  end

  defp example_names do
    @examples
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@examples, &1)))
    |> Enum.sort()
  end

  defp read(name, path), do: File.read!(Path.join([@examples, name, path]))
end
