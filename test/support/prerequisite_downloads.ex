defmodule Monty.Test.PrerequisiteDownloads do
  @moduledoc """
  Cleanup for tests that start downloads.

  A download outlives the test that started it unless something stops it, and
  a stray process writing into a deleted temporary directory fails in a way
  that has nothing to do with the test at hand.
  """

  @spec stop_all() :: :ok
  def stop_all do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(ExTbpMonty.PrerequisitesSupervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(ExTbpMonty.PrerequisitesSupervisor, pid)
    end

    :ok
  end
end
