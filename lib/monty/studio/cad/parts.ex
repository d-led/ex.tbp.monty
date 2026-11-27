defmodule Monty.Studio.Cad.Parts do
  @moduledoc """
  The STEP parts this machine can run, and how one gets here.

  A part is a file, so the domain is small and the decisions are all at the
  edge: **where** a part lives (`Monty.Studio.Setup.parts_dirs/0` — the data
  directory first, the ones the application ships behind it), **what may become
  one** (a name that can be a directory and a memory prefix, and bytes the
  kernel reads as a part), and **what happens to a name already taken**. Nothing
  after `install/2` re-checks a file: the name it kept is the name a memory, an
  object directory and a run all answer to.

  Bringing a part in is deliberately idempotent and deliberately not
  overwriting: the same bytes are the same part and answer the same file, while
  other bytes under a used name are refused, because every memory taught from
  that name describes the file that was there when it was taught
  (`Monty.Studio.Cad.Taught` keeps that note).

  `describe/1` is the recognition's answer about a part — its size, its faces
  and the features quiddity found — which is what a page shows beside the file
  and what a generated run's object names come from.
  """

  alias Monty.Studio.Setup

  # A name becomes a directory in the object set and the head of a memory's
  # name (`bracket_part`), so it takes what both can carry: lowercase, digits,
  # `_` and `-`, starting with one of the first two.
  @name ~r/^[a-z0-9][a-z0-9_-]*$/

  @enforce_keys [:name, :path, :bytes]
  defstruct [:name, :path, :bytes]

  @typedoc "A part on this machine: its name, the file, and how big it is."
  @type t :: %__MODULE__{name: String.t(), path: Path.t(), bytes: non_neg_integer()}

  @typedoc """
  What the recognition says about a part.

  `features` is in the recognition's own order, and `verified?` is its
  `evidence_status` — a feature it could not prove is still a feature, and a
  page has to be able to say which is which.
  """
  @type description :: %{
          name: String.t(),
          path: Path.t(),
          extent: [float()],
          faces: non_neg_integer(),
          features: [%{id: String.t(), family: String.t(), verified?: boolean()}]
        }

  @doc "Where a part this machine brought is written."
  @spec dir() :: Path.t()
  def dir, do: Setup.parts_dir()

  @doc """
  Every part the worlds would look for, the data directory's first.

  Which files are parts is `Monty.Studio.Setup.cad_parts/0`'s answer, not this
  module's: a name here resolves exactly the way `MONTY_CAD_PART` and an
  experiment's `object_names` resolve it.
  """
  @spec list() :: [t()]
  def list, do: Enum.map(Setup.cad_parts(), &part/1)

  @doc "The part a name answers to."
  @spec find(String.t()) :: {:ok, t()} | {:error, String.t()}
  def find(name) do
    case Enum.find(list(), &(&1.name == name)) do
      nil ->
        {:error,
         "there is no part #{inspect(name)}: #{Enum.map_join(Setup.parts_dirs(), " and ", &"#{&1}")} hold " <>
           inspect(Enum.map(list(), & &1.name))}

      part ->
        {:ok, part}
    end
  end

  @doc """
  A file's bytes as the part `name` names.

  The bytes are read before anything is written, and the file only takes the
  name once the kernel has read it as a part, so a refused upload leaves the
  directory as it was. The same bytes under the same name are the same part; a
  different file under a used name is refused with the file that holds it, so
  nobody has to guess which one a memory was taught from.
  """
  @spec install(String.t(), binary()) :: {:ok, t()} | {:error, String.t()}
  # sobelow_skip ["Traversal.FileModule"]
  # The path compared here is the one `list/0` found under `Setup.parts_dirs/0`,
  # not a request's: the name was checked before it was joined onto anything.
  def install(name, bytes) when is_binary(bytes) do
    with :ok <- check_name(name) do
      case Enum.find(list(), &(&1.name == name)) do
        %__MODULE__{path: path} = existing ->
          if File.read!(path) == bytes,
            do: {:ok, existing},
            else: {:error, taken(name, path)}

        nil ->
          write(name, bytes)
      end
    end
  end

  @doc """
  What the recognition says about the part a name answers to.

  This is the one place quiddity is asked about a part here. A node without the
  CAD packages answers with the sentence rather than raising, because the page
  that shows a part is not the place to find out that a dependency is missing.
  """
  @spec describe(String.t()) :: {:ok, description()} | {:error, String.t()}
  def describe(name) do
    with {:ok, part} <- find(name),
         {:ok, opened} <- open(part.path),
         {:ok, recognition} <- features(opened) do
      {:ok,
       %{
         name: name,
         path: part.path,
         extent: Quiddity.Part.extent(opened),
         faces: Quiddity.Part.face_count(opened),
         features: features_of(recognition)
       }}
    end
  end

  # -- the file ------------------------------------------------------------

  defp part(file) do
    path =
      Enum.find_value(Setup.parts_dirs(), fn directory ->
        candidate = Path.join(directory, file)
        if File.regular?(candidate), do: candidate
      end)

    %__MODULE__{name: Path.rootname(file), path: path, bytes: File.stat!(path).size}
  end

  # The file is written under a name no other install uses and renamed into
  # place, so a part is either complete or absent — never half a file a run
  # could open.
  #
  # sobelow_skip ["Traversal.FileModule"]
  # Both paths are built from `dir/0` and a name this module already checked
  # against its own pattern, plus a counter of this VM's; neither is a request's.
  defp write(name, bytes) do
    File.mkdir_p!(dir())
    incoming = Path.join(dir(), ".#{name}-#{System.unique_integer([:positive])}.incoming")
    path = Path.join(dir(), name <> ".step")

    with :ok <- File.write(incoming, bytes),
         :ok <- readable(incoming),
         :ok <- File.rename(incoming, path) do
      {:ok, %__MODULE__{name: name, path: path, bytes: byte_size(bytes)}}
    else
      {:error, sentence} when is_binary(sentence) ->
        File.rm(incoming)
        {:error, sentence}

      {:error, reason} ->
        File.rm(incoming)
        {:error, "#{inspect(name)} could not be written: #{:file.format_error(reason)}"}
    end
  end

  defp readable(path) do
    case open(path) do
      {:ok, _part} -> :ok
      {:error, sentence} -> {:error, "the file could not be read as a STEP part (#{sentence})"}
    end
  end

  defp check_name(name) do
    if is_binary(name) and Regex.match?(@name, name) do
      :ok
    else
      {:error,
       "a part's name becomes a directory and a memory, so it takes letters, digits, `_` and `-` " <>
         "and starts with a letter or a digit: #{inspect(name)}"}
    end
  end

  defp taken(name, path) do
    "#{inspect(name)} is already a part — #{path} — and these are other bytes; " <>
      "a memory taught from it would describe a file that is no longer here. Choose another name."
  end

  # -- the recognition -----------------------------------------------------

  defp open(path) do
    if Code.ensure_loaded?(Quiddity) do
      case Quiddity.open(path) do
        {:ok, part} -> {:ok, part}
        {:error, reason} -> {:error, Exception.message(reason)}
      end
    else
      {:error, "the CAD packages are not on this node, so a part cannot be read"}
    end
  end

  defp features(opened) do
    case Quiddity.features(opened) do
      {:ok, recognition} -> {:ok, recognition}
      {:error, reason} -> {:error, Exception.message(reason)}
    end
  end

  defp features_of(recognition) do
    recognition
    |> Quiddity.Recognition.records()
    |> Enum.map(fn record ->
      %{
        id: record["id"],
        family: record["family"],
        verified?: record["evidence_status"] == "verified"
      }
    end)
  end
end
