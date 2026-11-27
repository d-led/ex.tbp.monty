defmodule Monty.Path do
  @moduledoc """
  Where Monty's data lives.

  Mirrors `tbp/monty/path.py`. A caller that has a path of its own keeps it; a
  caller that does not gets the one under `MONTY_DATA`, which is where Monty's
  pretrained resources and its test fixtures are checked out.
  """

  @doc """
  The data path a caller should use.

  A custom path wins outright — `default_subpath` is only consulted when there is
  none — and an empty custom path is the current directory, as Python's `Path("")`
  is. An unset `MONTY_DATA` raises, because a default that silently points
  somewhere else is a run reading the wrong data.
  """
  @spec monty_data_path(String.t() | nil, String.t()) :: Path.t()
  def monty_data_path(nil, default_subpath) do
    Path.join(System.fetch_env!("MONTY_DATA"), default_subpath)
  end

  def monty_data_path(custom_data_path, _default_subpath) do
    normalise(custom_data_path)
  end

  defp normalise(""), do: "."
  defp normalise(path), do: path
end
