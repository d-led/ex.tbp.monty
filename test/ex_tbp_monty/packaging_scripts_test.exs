defmodule ExTbpMonty.PackagingScriptsTest do
  # Where a release lands is written twice: once in the Tauri resource mapping,
  # which copies it into a bundle, and once in each packaging script, which then
  # has to *ask about it* — `scripts/check-release.sh` refuses a release that
  # carries a checkout's debris, and it can only refuse one it can see. The Linux
  # line asked at `rel`, one directory above the release, so the check answered
  # "no application priv" and failed a bundle that was correct; nobody saw it
  # because that job only starts once every other gate is green.
  use ExUnit.Case, async: true

  @tauri_config "src-tauri/tauri.bundle.conf.json"
  @packaging_scripts ~w(scripts/package.sh scripts/start-desktop.sh)

  test "every bundle is checked where the resource mapping puts the release" do
    destination = disk_release_destination()
    asked_at = @packaging_scripts |> Enum.flat_map(&release_checks_in/1)

    assert asked_at != [],
           "no packaging script runs #{script_name()}: the check that keeps a bundle lean is gone"

    for {script, path} <- asked_at do
      assert String.ends_with?(path, destination),
             "#{script} checks #{path}, but a bundle carries the release at #{destination}"
    end
  end

  # `"../_build/desktop/rel/ex_tbp_monty": "rel/ex_tbp_monty"` — the right-hand
  # side is where the release is inside every bundle, whatever the platform.
  defp disk_release_destination do
    @tauri_config
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["bundle", "resources"])
    |> Map.values()
    |> Enum.uniq()
    |> case do
      [destination] -> destination
      destinations -> flunk("expected one bundled release, found #{inspect(destinations)}")
    end
  end

  # The scripts' own arguments, minus the ones a platform branch hands over as a
  # variable: a script that checks `"$release"` is checked against the release it
  # built, and that is the release the mapping names.
  defp release_checks_in(script) do
    asked = ~r/#{script_name()}\s+(\S+)/

    script
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&comment?/1)
    |> Enum.flat_map(&Regex.scan(asked, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&unquote_path/1)
    |> Enum.reject(&String.starts_with?(&1, "$"))
    |> Enum.map(&{script, &1})
  end

  # A platform branch quotes the path when it builds it from a product name with
  # spaces in it; the quotes are the shell's, not the path's.
  defp unquote_path(path), do: String.replace(path, ~r/^["']|["']$/, "")

  defp comment?(line), do: String.trim_leading(line) |> String.starts_with?("#")

  defp script_name, do: "check-release.sh"
end
