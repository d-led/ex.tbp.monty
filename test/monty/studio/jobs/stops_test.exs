defmodule Monty.Studio.Jobs.StopsTest do
  @moduledoc """
  A stop is asked once and read by every process stepping the run — the worker
  that owns the clock and the tasks it started, whose mailboxes are their own.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Jobs.Stops

  test "a run that was not asked has not been asked" do
    refute Stops.asked?("00000000-0000-4000-8000-000000000000")
  end

  test "a run that was asked has been asked, from any process" do
    run_id = "7b1f0a2a-0000-4000-8000-000000000001"

    task = Task.async(fn -> Stops.ask(run_id) end)
    Task.await(task)

    assert Stops.asked?(run_id)
  end

  test "a closed run forgets it was asked, so the same id started again is not stopped" do
    run_id = "7b1f0a2a-0000-4000-8000-000000000002"

    Stops.ask(run_id)
    assert Stops.asked?(run_id)

    Stops.clear(run_id)
    refute Stops.asked?(run_id)
  end
end
