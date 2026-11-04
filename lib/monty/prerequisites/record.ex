defmodule Monty.Prerequisites.Record do
  @moduledoc """
  What this application last did for a prerequisite, written beside it.

  A fetch is minutes of downloading and of reading pickles, and the process
  doing it lives no longer than the page that asked for it. Without something
  on disk, a restart left only the files: "three of eight models were exported
  and one could not be read" was gone, and the next visit re-discovered it by
  doing the work again — or, worse, reported the archive as ready because a
  directory held something.

  The record is that memory. It is **not** the authority on readiness: what is
  on disk is. A record that says done cannot make a deleted library present,
  which is why the saga derives every state from the filesystem and uses the
  record only for the two things the filesystem cannot say — whether the
  unpacking ever finished, and what the last export made of each model.

  It sits next to the file the fetch produces, so it travels with the data it
  describes: delete the archive and the record beside it, and the machine is
  back at the beginning, which is the truth.
  """

  alias Monty.Prerequisites

  @doc """
  Where the record for a prerequisite lives.

  A dot-file beside the target, so a directory of downloads still reads as the
  downloads.
  """
  @spec path(Prerequisites.prerequisite()) :: Path.t()
  def path(%{id: id} = prerequisite) do
    Path.join(Path.dirname(Prerequisites.target_path(prerequisite)), ".#{id}.json")
  end

  @doc """
  The record, or `nil` when there is none this version can read.

  An unreadable or half-written record is the same as no record: the work is
  idempotent, so the cost of forgetting is doing it again.
  """
  @spec read(Prerequisites.prerequisite()) :: map() | nil
  def read(prerequisite) do
    with {:ok, text} <- File.read(path(prerequisite)),
         {:ok, record} when is_map(record) <- Jason.decode(text) do
      record
    else
      _absent_or_unreadable -> nil
    end
  end

  @doc """
  Replaces the record.

  Written through a `.part` file and renamed, so a reader never sees half a
  document: the record is read at boot by the application and at every visit to
  the prerequisites page.
  """
  @spec write(Prerequisites.prerequisite(), map()) :: :ok | {:error, term()}
  def write(prerequisite, record) do
    path = path(prerequisite)
    part = path <> ".part"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(part, Jason.encode!(Map.put(record, "updated_at", now()))),
         :ok <- File.rename(part, path) do
      :ok
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
