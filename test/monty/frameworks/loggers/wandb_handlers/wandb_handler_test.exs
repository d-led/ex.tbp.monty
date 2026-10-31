defmodule Monty.Frameworks.Loggers.WandbHandlers.WandbHandlerTest do
  @moduledoc """
  The hand-written part of a wandb handler's parent: the columns a table cannot be
  built from, and the count a handler keeps of its own reports.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.WandbHandlers.WandbHandler

  defmodule Counter do
    @moduledoc false
    @behaviour WandbHandler

    defstruct reports: 0

    @impl true
    def report_count(%__MODULE__{reports: reports}), do: reports

    @impl true
    def report_episode(
          %__MODULE__{reports: reports},
          _data,
          _output_dir,
          _episode,
          _mode,
          _episodes_to_total
        ),
        do: {:ok, %__MODULE__{reports: reports + 1}}
  end

  test "names the columns whose length differs from episode to episode" do
    # A table built from one of these has a column that is a value in one episode
    # and a list in the next, which is the shape wandb refuses.
    assert WandbHandler.variable_length_columns() == [
             "possible_object_poses",
             "possible_object_locations",
             "possible_object_sources",
             "possible_match_sources",
             "detected_path"
           ]
  end

  test "a handler answers a value and counts the episodes it reported" do
    # The behaviour's two obligations, held by a handler that satisfies them: the
    # wrapper threads the value, and the count says which report is the later one.
    assert {:ok, %Counter{reports: 1}} =
             Counter.report_episode(%Counter{}, %{}, "/tmp", 0, :train, %{})

    assert Counter.report_count(%Counter{reports: 3}) == 3
  end
end
