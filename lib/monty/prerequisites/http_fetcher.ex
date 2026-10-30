defmodule Monty.Prerequisites.HttpFetcher do
  @moduledoc """
  Streams a URL into a file with `Req`.

  The body never sits in memory: each chunk is written as it arrives and
  reported to the downloader, so the UI can show bytes, speed and ETA while a
  large archive is still arriving. `Req` follows the object-store redirects the
  pretrained-model links use and retries a transient connection failure.
  """

  @behaviour Monty.Prerequisites.Fetcher

  @impl true
  # `path` is the destination the prerequisite list names under the data
  # directory; nothing a request says reaches here.
  # sobelow_skip ["Traversal.FileModule"]
  def download(url, path, on_chunk, opts) do
    on_total = Keyword.get(opts, :on_total, fn _total -> :ok end)

    {:ok, response} = File.open(path, [:write, :binary], &fetch(&1, url, on_chunk, on_total))

    case response.status do
      status when status in 200..299 -> {:ok, File.stat!(path).size}
      status -> {:error, {:http_status, status}}
    end
  end

  defp fetch(file, url, on_chunk, on_total) do
    Req.get!(url,
      into: fn {:data, chunk}, {request, response} ->
        report_total(response, on_total)
        :ok = IO.binwrite(file, chunk)
        on_chunk.(byte_size(chunk))
        {:cont, {request, response}}
      end,
      decode_body: false,
      # A 404 is a manifest problem, not an exception: the status is reported
      # and the downloader removes its .part file.
      http_errors: :return,
      retry: :transient,
      max_retries: 3,
      receive_timeout: 120_000
    )
  end

  defp report_total(response, on_total) do
    with %{"content-length" => [length | _]} <- response.headers,
         {total, ""} <- Integer.parse(length) do
      on_total.(total)
    else
      _ -> :ok
    end
  end
end
