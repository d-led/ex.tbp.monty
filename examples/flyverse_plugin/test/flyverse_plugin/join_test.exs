defmodule FlyversePlugin.JoinTest do
  @moduledoc """
  Where the node joins, read from the environment — the case that matters most is
  the one with nowhere to join: a node in no cluster runs, answers `rpc`, and
  says nothing anywhere unless `Join` says it.

  Not `async`: the cases read a variable the whole VM shares.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlyversePlugin.Join

  setup do
    before = System.get_env("MONTY_SEEDS")
    on_exit(fn -> restore(before) end)
  end

  test "a node with nothing to reach says so once, rather than staying silent" do
    System.delete_env("MONTY_SEEDS")

    log =
      capture_log(fn ->
        join = start_supervised!({Join, name: :flyverse_join_without_seeds})
        # The first attempt is a message the process sends itself; the state is
        # how the test waits for it rather than sleeping.
        assert %{reached: [], seeds: []} = :sys.get_state(join)
      end)

    assert log =~ "not in a cluster (no seed answered from MONTY_SEEDS)"
  end

  defp restore(nil), do: System.delete_env("MONTY_SEEDS")
  defp restore(value), do: System.put_env("MONTY_SEEDS", value)
end
