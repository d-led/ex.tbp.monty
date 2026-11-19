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
  holds, when it was written, and — for a note written since 2026-11-19 — the
  inputs themselves, so a disagreement can say *which* one moved rather than only
  that one did: `%{"optics" => …, "parts" => …, "versions" => …}`.

  `provenance` is `nil` for a note written before those three were kept. Nothing
  is inferred then: an old note still answers "this is not what the config would
  teach", which is what it is for.
  """
  # A JSON object, as `JSON.decode/1` gives it back: string keys, values that are
  # maps, lists or scalars. A typespec's map cannot spell a string key, so this
  # says the shape it is.
  @type inputs :: %{optional(String.t()) => term()}

  @type provenance :: %{
          fingerprint: String.t(),
          nodes: non_neg_integer(),
          at: String.t(),
          inputs: inputs() | nil
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
  # sobelow_skip ["Traversal.FileModule"]
  # The path is derived from the memory's own path, which the config names: no
  # part of it comes from a request.
  @spec read(Path.t()) :: {:ok, provenance()} | :none
  def read(memory) do
    record = path(memory)

    with true <- File.regular?(memory),
         {:ok, text} <- File.read(record),
         {:ok, document} <- JSON.decode(text),
         %{"fingerprint" => fingerprint, "nodes" => nodes, "at" => at} <- document,
         true <- is_binary(fingerprint) and is_integer(nodes) and is_binary(at) do
      {:ok, %{fingerprint: fingerprint, nodes: nodes, at: at, inputs: inputs_of(document)}}
    else
      _not_a_record -> :none
    end
  end

  defp inputs_of(%{"optics" => _optics, "parts" => _parts, "versions" => _versions} = document),
    do: Map.take(document, ["optics", "parts", "versions"])

  defp inputs_of(_without_them), do: nil

  @doc """
  Writes the note beside `memory`, which has just been taught.

  `inputs` is what the fingerprint was made from, in the JSON shape the note is
  read back in — the optics, the part files' digests and the packages' versions —
  so a reader can say which of them moved rather than only that one did. An
  empty map is a note that knows only its fingerprint, which is what the first
  version of this wrote.

  Answers a sentence rather than a bare reason: a build that cannot record what
  it taught is a build that will teach it again, and a person reading the row
  should be told that instead of a `:eacces`.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # Beside the memory it describes, under the same libraries root: the path comes
  # from the config, not from a request.
  @spec remember(Path.t(), String.t(), non_neg_integer(), map()) :: :ok | {:error, String.t()}
  def remember(memory, fingerprint, nodes, inputs \\ %{}) do
    record =
      Map.merge(
        %{
          "fingerprint" => fingerprint,
          "nodes" => nodes,
          "at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        Map.take(inputs, ["optics", "parts", "versions"])
      )

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
