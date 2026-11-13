defmodule ExamplePlugin.JoinTest do
  @moduledoc """
  Where the node joins, read from the environment — the one 12-factor decision
  this example makes that a test can hold without a second VM.

  Not `async`: the cases read a variable the whole VM shares, and one of them
  unsets it.
  """

  use ExUnit.Case, async: false

  alias ExamplePlugin.Join

  setup do
    before = System.get_env("MONTY_SEEDS")
    on_exit(fn -> restore(before) end)
  end

  test "seeds are the node names the deployment wrote, in the spelling OTP uses" do
    System.put_env("MONTY_SEEDS", "node1@127.0.0.1, node2@127.0.0.1")

    assert Join.seeds() == [:"node1@127.0.0.1", :"node2@127.0.0.1"]
  end

  test "a node with no seeds is a node that runs alone, not a mistake" do
    System.delete_env("MONTY_SEEDS")

    assert Join.seeds() == []
  end

  defp restore(nil), do: System.delete_env("MONTY_SEEDS")
  defp restore(value), do: System.put_env("MONTY_SEEDS", value)
end
