defmodule Mix.Tasks.Cover.Merge do
  @shortdoc "Merges the coverage each test partition exported into one file"

  @moduledoc """
  Combines the coverage files the test partitions exported into the one file the
  CRAP ranking reads.

      mix cover.merge

  `mix test --partitions N --cover` writes `cover/<partition>.coverdata`, one
  per partition, and `mix test.coverage` reports their total without leaving a
  file behind. `mix crap` reads `cover/default.coverdata`, so the total needs a
  file of its own: import every partition's export, then export once.

  The inputs are `cover/*.coverdata` except `default.coverdata` — merging a
  merge would count the same lines twice — and finding nothing to merge is an
  error rather than an empty report, because an empty report looks exactly like
  a green one.
  """

  use Mix.Task

  # `:cover` is Erlang's, from the `tools` application: present whenever this
  # task can be useful (`mix test --cover` starts it), but not compiled as part
  # of this project, so the compiler would warn about every call below.
  @compile {:no_warn_undefined, :cover}

  @glob "cover/*.coverdata"
  @output "cover/default.coverdata"
  @merged Path.basename(@output)

  @impl true
  def run(_args) do
    case merge(input_files(Path.wildcard(@glob)), @output) do
      {:ok, count} ->
        Mix.shell().info("merged #{count} coverage export(s) into #{@output}")

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  @doc """
  Which of the exported files are inputs: everything but the merge's own output,
  sorted so the merge does not depend on the order the filesystem lists them in.
  """
  @spec input_files([Path.t()]) :: [Path.t()]
  def input_files(paths) do
    paths
    |> Enum.reject(&(Path.basename(&1) == @merged))
    |> Enum.sort()
  end

  @doc """
  Merges `paths` into `output`, and says how many files it read.

  Nothing to merge is a `{:error, reason}` rather than an empty export: a test
  run that produced no coverage at all has not answered the question the CRAP
  ranking asks, and an empty file would answer it with zeroes.
  """
  @spec merge([Path.t()], Path.t()) :: {:ok, pos_integer()} | {:error, String.t()}
  def merge([], _output), do: {:error, "no coverage exports to merge (looked for #{@glob})"}

  def merge(paths, output) do
    start_cover()

    with :ok <- import_all(paths),
         :ok <- export(output) do
      {:ok, length(paths)}
    end
  end

  defp import_all(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case :cover.import(to_charlist(path)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "could not import #{path}: #{inspect(reason)}"}}
      end
    end)
  end

  defp export(output) do
    File.mkdir_p!(Path.dirname(output))

    case :cover.export(to_charlist(output)) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not export #{output}: #{inspect(reason)}"}
    end
  end

  # `mix test.coverage` starts a cover server of its own; a second start is a
  # success from this task's point of view.
  defp start_cover do
    case :cover.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
