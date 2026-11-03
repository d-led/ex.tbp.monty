defmodule Mix.Tasks.Monty.Prerequisites.Fetch do
  @shortdoc "Downloads the prerequisites an experiment needs, and exports their memory"

  @moduledoc """
  Fetches what an experiment needs before it can run, without a browser.

      mix monty.prerequisites.fetch                     # everything the manifest names
      mix monty.prerequisites.fetch pretrained_ycb_v14  # one entry, by id

  Each entry is downloaded to the path `priv/prerequisites.yaml` gives it,
  unpacked when it is an archive, and — for a pretrained archive — exported into
  the libraries `Monty.Studio.Memory` reads. That last step is the same one
  `/prerequisites` runs, and it is idempotent: an archive that is already here is
  checked rather than downloaded again, and a library newer than the pickle it
  came from is left alone.

  This is what a CI job or a fresh container calls before running the suite:
  Monty's models are data, and this is how the data arrives.

  Exit status is 1 when any entry failed, with the reason, so the task is usable
  from a script.
  """

  use Mix.Task

  alias Monty.Prerequisites

  @requirements ["app.start"]

  @impl true
  def run(arguments) do
    Prerequisites.all()
    |> wanted(arguments)
    |> Enum.map(&fetch/1)
    |> report()
  end

  defp wanted(entries, []), do: entries

  defp wanted(entries, ids) do
    unknown = ids -- Enum.map(entries, & &1.id)

    if unknown != [] do
      Mix.raise(
        "no prerequisite #{Enum.join(unknown, ", ")}; the manifest names " <>
          Enum.map_join(entries, ", ", & &1.id)
      )
    end

    Enum.filter(entries, &(&1.id in ids))
  end

  # The downloader runs in a process of its own from the moment it starts, so
  # waiting is a subscription rather than a call — the same messages the page
  # gets, which is what makes this the same fetch a person would see. The
  # waiting itself is `Monty.Prerequisites.fetch/1`, so the release command
  # that fetches before a container serves waits the same way.
  defp fetch(prerequisite) do
    Mix.shell().info("#{prerequisite.id}: fetching")

    case Prerequisites.fetch(prerequisite) do
      {:ok, progress} ->
        Mix.shell().info("#{prerequisite.id}: #{describe(progress)}")
        :ok

      {:error, reason} ->
        Mix.shell().error("#{prerequisite.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp describe(%{libraries: %{exported: exported, current: current}}) do
    "memory exported: #{length(exported)} written, #{length(current)} already current"
  end

  defp describe(_progress), do: "present"

  defp report(results) do
    case Enum.reject(results, &(&1 == :ok)) do
      [] -> :ok
      failures -> Mix.raise("#{length(failures)} prerequisite(s) did not arrive")
    end
  end
end
