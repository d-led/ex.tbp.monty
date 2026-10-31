defmodule Monty.Frameworks.Loggers.WandbHandlers.WandbHandler do
  @moduledoc """
  `tbp/monty/frameworks/loggers/wandb_handlers.py::WandbHandler`.

  The contract a wandb handler meets: a `MontyHandler` that is handed an episode's
  pool by `WandbWrapper` rather than filtering it out of the log itself, and that
  knows which of its columns change length from episode to episode.

  Monty keeps those column names here, on the parent, and not on each handler: a
  table built from a column that is one value in one episode and a list in the next
  is a table wandb refuses, so the list is shared knowledge rather than a detail of
  whoever happened to build the table.
  """

  alias Monty.Frameworks.Experiments.Mode.ExperimentMode
  alias Monty.Frameworks.Loggers.MontyHandlers.MontyHandler

  @doc """
  The columns whose length differs per episode, so no table is built from them.

  Monty's list, in its order.
  """
  @spec variable_length_columns() :: [String.t()]
  def variable_length_columns do
    [
      "possible_object_poses",
      "possible_object_locations",
      "possible_object_sources",
      "possible_match_sources",
      "detected_path"
    ]
  end

  @doc """
  How many episodes this handler has reported.

  Monty counts its reports and its table handlers say so, which is how a handler
  asked twice in one episode can tell its two answers apart.
  """
  @callback report_count(handler :: struct()) :: non_neg_integer()

  @doc """
  Reports one episode's logs, returning the handler with what it recorded.

  The same six arguments a `MontyHandler` is given, because a wandb handler is one:
  the wrapper hands it the pool and it answers a value. Nothing is sent from here —
  the wrapper is what commits, once per episode, so the run's global step stays
  under its control.
  """
  @callback report_episode(
              handler :: struct(),
              data :: MontyHandler.logs(),
              output_dir :: Path.t(),
              episode :: non_neg_integer(),
              mode :: ExperimentMode.t(),
              episodes_to_total :: %{optional(non_neg_integer()) => integer()}
            ) :: {:ok, struct()} | {:error, term()}
end
