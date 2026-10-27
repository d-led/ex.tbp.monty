defmodule Monty.Runtime.Registry do
  @moduledoc """
  Names for module processes.

  Every sensor and learning module registers a stable key
  (`{:sensor_module, model_id, id}`, `{:learning_module, model_id, id}`), and
  the coordinator addresses it with a `:via` tuple. A restart changes the pid
  but not the name, so nothing in the step loop has to be rewritten when a
  module dies. The model id in the key lets several runs share one registry
  without inventing an atom per run.
  """

  @registry __MODULE__

  @doc "The application-wide registry module processes register in."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "A `:via` name for a key."
  @spec via(term()) :: {:via, Registry, {atom(), term()}}
  def via(key), do: {:via, Registry, {registry(), key}}

  @doc "The processes registered under a key."
  @spec lookup(term()) :: [{pid(), term()}]
  def lookup(key), do: Elixir.Registry.lookup(registry(), key)
end
