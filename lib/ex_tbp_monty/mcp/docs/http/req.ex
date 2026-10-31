defmodule ExTbpMonty.Mcp.Docs.Http.Req do
  @moduledoc """
  `Req`, pointed at a documentation site.

  `http_errors: :return` because a `404` is an answer — the page was renamed, or
  never existed — and an exception is the one thing an MCP tool must not do
  with it. `decode_body: false` so the caller decides what a body is: the same
  function brings back page markdown, search JSON and a plain-text page index.
  """

  @behaviour ExTbpMonty.Mcp.Docs.Http

  @impl true
  def get(url) do
    case Req.get(url,
           decode_body: false,
           http_errors: :return,
           retry: :transient,
           max_retries: 1,
           connect_options: [timeout: 5_000],
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
