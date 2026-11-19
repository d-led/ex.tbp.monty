defmodule Monty.Studio.Cad.Taught do
  @moduledoc """
  What a memory was taught from, kept beside it.

  Re-teaching a memory from the part file and the optics it was already taught
  from is minutes of geometry for nothing: one Make click writes five CAD
  memories and took twelve minutes on a ten-core Mac (2026-11-19), most of it the
  blend and the two-part set at a patch's own scale. A record beside the file is
  what makes a second click cheap *and* keeps the page honest — the build skips
  only when the fingerprint it would teach from is the one the file was written
  from, and a changed part file, a changed stand-off or lens, a changed sampling
  cap or a new CAD package each change the fingerprint. So a skip cannot hide a
  memory that no longer matches its config; it hides nothing that changed.

  It is `<memory>.taught.json` beside the `.jsonl.gz`. Nothing lists libraries by
  that name — `Monty.Studio.Memory` reads `.jsonl.gz` and `Monty.Prerequisites`
  joins `<name>.jsonl.gz` — so a release directory can hold these and no reader
  sees them.
  """

  @extension ".taught.json"

  @typedoc """
  A memory's provenance: the fingerprint of what produced it, how many nodes it
  holds, and when it was written.
  """
  @type provenance :: %{
          fingerprint: String.t(),
          nodes: non_neg_integer(),
          at: String.t()
        }

  @doc """
  Where a memory's record lives: its own name with `.taught.json` for a suffix.
  """
  @spec path(Path.t()) :: Path.t()
  def path(memory), do: Path.rootname(memory, ".jsonl.gz") <> @extension

  @doc """
  The record beside `memory`, or `:none`.

  `:none` for every reason a skip would be unsafe — no memory file, no record,
  a record that is not one of ours — because the caller's only question is
  whether it may skip, and every one of those answers is no.
  """
  @spec read(Path.t()) :: {:ok, provenance()} | :none
  def read(memory) do
    record = path(memory)

    with true <- File.regular?(memory),
         {:ok, text} <- File.read(record),
         {:ok, document} <- JSON.decode(text),
         %{"fingerprint" => fingerprint, "nodes" => nodes, "at" => at} <- document,
         true <- is_binary(fingerprint) and is_integer(nodes) and is_binary(at) do
      {:ok, %{fingerprint: fingerprint, nodes: nodes, at: at}}
    else
      _not_a_record -> :none
    end
  end

  @doc """
  Writes `record` beside `memory`, which has just been taught.

  Answers a sentence rather than a bare reason: a build that cannot record what
  it taught is a build that will teach it again, and a person reading the row
  should be told that instead of a `:eacces`.
  """
  @spec remember(Path.t(), %{fingerprint: String.t(), nodes: non_neg_integer()}) ::
          :ok | {:error, String.t()}
  def remember(memory, %{fingerprint: fingerprint, nodes: nodes}) do
    record = %{
      "fingerprint" => fingerprint,
      "nodes" => nodes,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case File.write(path(memory), JSON.encode!(record)) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         "#{Path.basename(memory)} was written but what it was taught from could not be " <>
           "kept beside it (#{reason}), so the next build will teach it again"}
    end
  end
end
