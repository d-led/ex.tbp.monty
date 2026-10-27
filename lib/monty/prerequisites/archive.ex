defmodule Monty.Prerequisites.Archive do
  @moduledoc """
  Unpacking a prerequisite that arrives as an archive.

  Monty's getting-started instructions say "download this and unpack it into
  `~/tbp/results/monty/pretrained_models`", and a downloaded `.tgz` that nobody
  unpacked is a prerequisite that looks present and is not. So unpacking is part
  of the download: the archive is unpacked next to itself, which is where its
  own top-level directory then appears, and how many files came out is reported
  rather than assumed.

  Only the formats Monty's manifest ships are handled — a tar with gzip and a
  zip — and anything else is an error with the path in it, not a silent no-op.
  """

  @type result :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Unpacks an archive into the directory it sits in."
  @spec extract(Path.t()) :: result()
  def extract(path) do
    into = Path.dirname(path)

    case format(path) do
      :tar -> extract_tar(path, into)
      :zip -> extract_zip(path, into)
      :unknown -> {:error, {:not_an_archive, path}}
    end
  end

  @doc "Which kind of archive a path names."
  @spec format(Path.t()) :: :tar | :zip | :unknown
  def format(path) do
    cond do
      String.ends_with?(path, [".tgz", ".tar.gz"]) -> :tar
      String.ends_with?(path, ".zip") -> :zip
      true -> :unknown
    end
  end

  defp extract_tar(path, into) do
    with {:ok, names} <- :erl_tar.table(to_charlist(path), [:compressed]),
         :ok <- extract_tar_files(path, into) do
      {:ok, length(names)}
    else
      {:error, reason} -> {:error, {:cannot_extract, path, reason}}
    end
  end

  defp extract_tar_files(path, into) do
    :erl_tar.extract(to_charlist(path), [:compressed, {:cwd, to_charlist(into)}])
  end

  defp extract_zip(path, into) do
    case :zip.unzip(to_charlist(path), [{:cwd, to_charlist(into)}]) do
      {:ok, names} -> {:ok, length(names)}
      {:error, reason} -> {:error, {:cannot_extract, path, reason}}
    end
  end
end
