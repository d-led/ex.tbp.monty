defmodule Monty.DataProvenance do
  @moduledoc """
  Where every piece of data in this tree came from, and proof it is still that.

  Data is what this application *reads*: Monty's config tree and the snapshots
  it composes into, the censuses taken of a checkout, the episodes recorded from
  Monty's own answers, the CAD parts a run steps. Each of those is described in
  `priv/data_provenance.yaml` — where it came from, whose it is, what produced
  it, and a hash — and this module checks the description against the bytes.

  Nothing arrives in a commit unexplained. A data file that no entry mentions is
  a failure, and so is an entry whose hash no longer matches: the record is
  either updated with the data or the data is re-generated from what the record
  names. That is also why no model is checked in at all: a pretrained memory is
  produced by a release and arrives through `/prerequisites`, so
  `priv/monty/libraries/` is gitignored and named here as a download instead.

  A hash is the file's sha256. For a directory it is the **tree hash**: the
  sha256 of the sorted lines `<relative path> <sha256 of that file>`, which
  answers "the same files with the same bytes" in one number and changes when a
  file is added, removed or edited — four hundred configs stated once rather
  than four hundred times.
  """

  @manifest "priv/data_provenance.yaml"

  # What counts as data. A `.md` or a `.ex` beside it is prose or source, whose
  # history is the repository's, not this record's.
  @extensions ~w(.yaml .yml .json .jsonl .csv .tsv .step .stp .npz .npy .gz)

  @type entry :: %{
          required(:path) => String.t(),
          required(:kind) => String.t(),
          required(:title) => String.t(),
          optional(:source) => String.t() | nil,
          optional(:licence) => String.t() | nil,
          optional(:produced_by) => String.t() | nil,
          optional(:hash) => String.t() | nil,
          optional(:note) => String.t() | nil
        }

  @type document :: %{
          required(:roots) => [String.t()],
          required(:exclude) => [String.t()],
          required(:data) => [entry()]
        }

  @doc """
  The record, read: the directories it covers, what it leaves out, and an entry
  per data set.
  """
  @spec manifest(Path.t()) :: document()
  def manifest(path \\ manifest_path()) do
    {:ok, document} = YamlElixir.read_from_file(path)

    %{
      roots: Map.get(document, "roots", []),
      exclude: Map.get(document, "exclude", []),
      data: document |> Map.get("data", []) |> Enum.map(&entry/1)
    }
  end

  @doc "Every data set this record describes."
  @spec entries(Path.t()) :: [entry()]
  def entries(path \\ manifest_path()), do: manifest(path).data

  @doc """
  The sha256 of a file, or the tree hash of a directory.
  """
  @spec hash_of(Path.t()) :: String.t()
  def hash_of(path) do
    if File.dir?(path), do: tree_hash(path), else: file_hash(path)
  end

  @doc "The sha256 of a file, as lowercase hex."
  @spec file_hash(Path.t()) :: String.t()
  def file_hash(path) do
    path
    |> File.stream!(65_536, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  One number for a directory: the same files with the same bytes.

  Sorted so that the order a file system hands paths back cannot change the
  answer, and relative to the directory so that moving the tree does not either.
  """
  @spec tree_hash(Path.t()) :: String.t()
  def tree_hash(directory) do
    directory
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn file -> "#{Path.relative_to(file, directory)} #{file_hash(file)}\n" end)
    |> Enum.sort()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  What is wrong with the record, in four lists:

    * `missing` — an entry whose path is not there
    * `unhashed` — an entry that says no sha256, or something that is not one
    * `drifted` — an entry whose path hashes to something else
    * `undeclared` — a data file the record does not mention

  Empty everywhere is a record that matches the tree.
  """
  @spec check(Path.t()) :: %{
          missing: [String.t()],
          unhashed: [String.t()],
          drifted: [%{path: String.t(), expected: String.t(), actual: String.t()}],
          undeclared: [String.t()]
        }
  def check(path \\ manifest_path()) do
    document = manifest(path)
    {present, absent} = document.data |> Enum.split_with(&File.exists?(&1.path))
    {recorded, unrecorded} = Enum.split_with(present, &digest?(&1[:hash]))

    %{
      missing: Enum.map(absent, & &1.path),
      unhashed: Enum.map(unrecorded, & &1.path),
      drifted: Enum.flat_map(recorded, &drift/1),
      undeclared: undeclared(document)
    }
  end

  # A hash is a sha256 or it is nothing: a digest of digits only is a number to
  # YAML, and accepting that would be a record that silently never matches.
  defp digest?(hash), do: is_binary(hash) and String.match?(hash, ~r/\A[0-9a-f]{64}\z/)

  defp drift(%{path: path, hash: hash}) do
    case hash_of(path) do
      ^hash -> []
      actual -> [%{path: path, expected: hash, actual: actual}]
    end
  end

  # A data file inside one of the covered directories that no entry names. An
  # entry for a directory covers everything under it.
  defp undeclared(document) do
    document.roots
    |> Enum.flat_map(fn root ->
      # A pattern is relative to a root and expanded inside it. One that named the
      # whole project would walk `deps/` and `_build/` for every check.
      excluded =
        document.exclude
        |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
        |> MapSet.new()

      data_files(root, excluded)
    end)
    |> Enum.reject(&declared?(document, &1))
    |> Enum.sort()
  end

  defp data_files(root, excluded) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&(File.regular?(&1) and Path.extname(&1) in @extensions))
    |> Enum.reject(&MapSet.member?(excluded, &1))
  end

  # A directory that is downloaded rather than committed is excluded by a
  # pattern, and so is the `.part` file a killed fetch leaves: neither is a blob
  # this repository carries, and the download's own record is the checksum in
  # `priv/prerequisites.yaml`.
  defp declared?(%{data: entries}, path) do
    Enum.any?(entries, fn %{path: covered} ->
      covered == path or String.starts_with?(path, covered <> "/")
    end)
  end

  defp entry(entry) do
    %{
      path: Map.fetch!(entry, "path"),
      kind: Map.fetch!(entry, "kind"),
      title: Map.fetch!(entry, "title"),
      source: Map.get(entry, "source"),
      licence: Map.get(entry, "licence"),
      produced_by: Map.get(entry, "produced_by"),
      hash: Map.get(entry, "hash"),
      note: Map.get(entry, "note")
    }
  end

  defp manifest_path do
    case :code.priv_dir(:ex_tbp_monty) do
      {:error, _} -> Path.join(File.cwd!(), @manifest)
      dir -> dir |> List.to_string() |> Path.join("data_provenance.yaml")
    end
  end
end
