defmodule Monty.Prerequisites.HttpFetcherTest do
  use ExUnit.Case, async: false

  alias Monty.Prerequisites.HttpFetcher

  setup do
    server = start_supervised!({Bandit, plug: Monty.Test.FixtureServer, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, url: "http://localhost:#{port}"}
  end

  test "streams the body to a file and reports chunks and length", %{url: url} do
    path = temp_path()
    parent = self()

    assert {:ok, 11} =
             HttpFetcher.download(
               url <> "/tiny.tgz",
               path,
               fn size -> send(parent, {:chunk, size}) end,
               on_total: fn total -> send(parent, {:total, total}) end
             )

    assert File.read!(path) == "hello world"
    assert_received {:chunk, 11}
    assert_received {:total, 11}
  end

  test "a 404 is an error, not an empty archive", %{url: url} do
    path = temp_path()

    assert {:error, {:http_status, 404}} =
             HttpFetcher.download(url <> "/missing.tgz", path, fn _ -> :ok end, [])
  end

  defp temp_path do
    path = Path.join(System.tmp_dir!(), "http-fetch-#{System.unique_integer([:positive])}.bin")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
