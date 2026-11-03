defmodule Monty.Studio.RunHistory.Json do
  @moduledoc """
  A JSON column that may hold a list.

  A run's log and timeline are arrays of objects. Postgres has `jsonb[]` for
  that, and SQLite has neither arrays nor a second type for them — one JSON
  document holds the same data and both adapters take it. Ecto's `:map` refuses
  a list, so this type tells the adapter "JSON" and lets the value be either a
  list or a map.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_list(value) or is_map(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(value) when is_list(value) or is_map(value), do: {:ok, value}
  def load(_value), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(value) when is_list(value) or is_map(value), do: {:ok, value}
  def dump(_value), do: :error
end
