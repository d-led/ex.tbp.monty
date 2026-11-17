defmodule Mix.Tasks.Monty.Data.Check do
  @shortdoc "Says what the data record no longer matches, and what to write"

  @moduledoc """
  Checks `priv/data_provenance.yaml` against the tree it describes.

      mix monty.data.check

  Prints four lists and exits non-zero when any of them is not empty:

    * a data file that no entry mentions — data arrived without its origin
    * an entry whose bytes changed — the new hash is printed, to write down once
      the change is understood
    * an entry that says no hash, or points at a path that is not there

  The same check is a test (`test/monty/data_provenance_test.exs`), so this task
  is how a person sees the answer without reading a failing assertion.
  """

  use Mix.Task

  alias Monty.DataProvenance

  @impl true
  def run(_args) do
    %{missing: missing, unhashed: unhashed, drifted: drifted, undeclared: undeclared} =
      DataProvenance.check()

    report = [
      section("data files with no entry", undeclared),
      section("entries pointing at nothing", missing),
      section("entries with no hash", unhashed),
      drifted
      |> Enum.map(fn drift ->
        "  #{drift.path}\n    recorded  #{drift.expected}\n    actual    #{drift.actual}"
      end)
      |> then(&section("entries whose bytes changed", &1))
    ]

    case Enum.reject(report, &is_nil/1) do
      [] -> Mix.shell().info("the data record matches the tree")
      [first | rest] -> Mix.raise(Enum.join([first | rest], "\n"))
    end
  end

  defp section(_title, []), do: nil

  defp section(title, lines) do
    Enum.join(["#{title}:", Enum.map(lines, &("  " <> &1))], "\n")
  end
end
