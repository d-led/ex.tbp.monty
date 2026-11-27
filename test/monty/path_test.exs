defmodule Monty.PathTest do
  @moduledoc """
  Translations of `tests/unit/path_test.py`.
  """

  use ExUnit.Case, async: true

  alias Monty.Path

  @mock_data "/monty/data"

  setup do
    previous = System.get_env("MONTY_DATA")
    System.put_env("MONTY_DATA", @mock_data)
    on_exit(fn -> restore(previous) end)
  end

  defp restore(nil), do: System.delete_env("MONTY_DATA")
  defp restore(value), do: System.put_env("MONTY_DATA", value)

  # test_monty_data_path (Monty's six parametrized rows)
  test "a caller's own path wins, and no path at all means MONTY_DATA" do
    # {custom_data_path, default_subpath, expected}
    rows = [
      {nil, "default/subpath", "/monty/data/default/subpath"},
      {nil, "", "/monty/data"},
      {"/custom/data/path", "default/subpath", "/custom/data/path"},
      {"/custom/already/path", "default/subpath", "/custom/already/path"},
      {nil, "sub/aspath", "/monty/data/sub/aspath"},
      # An empty custom path is the current directory.
      {"", "default/subpath", "."}
    ]

    for {custom, subpath, expected} <- rows do
      assert Path.monty_data_path(custom, subpath) == expected,
             "#{inspect(custom)} with #{inspect(subpath)} should be #{expected}"
    end
  end

  test "raises when there is no MONTY_DATA to fall back on" do
    System.delete_env("MONTY_DATA")

    assert_raise System.EnvError, fn -> Path.monty_data_path(nil, "default/subpath") end
  end
end
