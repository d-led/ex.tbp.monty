defmodule Monty.Test.FakeFetcher do
  @moduledoc """
  A fetcher that writes known chunks, so downloads can be tested without a
  network.

  Configure through the application environment:

      config :ex_tbp_monty,
        fake_download_chunks: ["hello", " ", "world"],
        fake_download_result: nil
  """

  @behaviour Monty.Prerequisites.Fetcher

  @impl true
  def download(_url, path, on_chunk, opts) do
    chunks = Application.get_env(:ex_tbp_monty, :fake_download_chunks, ["hello", " ", "world"])
    total = Enum.sum(Enum.map(chunks, &byte_size/1))

    if on_total = opts[:on_total], do: on_total.(total)

    File.open!(path, [:write, :binary], fn file ->
      Enum.each(chunks, fn chunk ->
        IO.binwrite(file, chunk)
        on_chunk.(byte_size(chunk))
      end)
    end)

    case Application.get_env(:ex_tbp_monty, :fake_download_result) do
      nil -> {:ok, total}
      result -> result
    end
  end
end
