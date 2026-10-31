defmodule ExTbpMonty.Mcp.Test.FakeDocsHttp do
  @moduledoc """
  A documentation site, served from a map.

  The documentation tools reach the published site through `:docs_http`, so a
  test names the bodies it expects and reads them as if they had come over the
  network — including the URLs, which are then part of what a test specifies: a
  query string that changes shape fails the test instead of quietly asking a
  different question.

      FakeDocsHttp.serve(%{
        "https://docs.thousandbrains.org/llms.txt" => "# …",
        search_url => ~s({"total": 0, "data": []}),
        page_url => {:error, :econnrefused},
        gone_url => {404, "gone"}
      })

  A URL mapped to a body answers `200`; `{status, body}` answers that status;
  `{:error, reason}` is a request that never reached anything. A URL that is
  not in the map is a `404`, which is what a site does with a page it does not
  have.
  """

  @behaviour ExTbpMonty.Mcp.Docs.Http

  alias Monty.Test.Tmp

  @doc "Serve `pages` as the site for this test, and put the settings back after."
  @spec serve(%{optional(String.t()) => term()}) :: :ok
  def serve(pages) do
    Tmp.app_env(:docs_http, __MODULE__)
    Tmp.app_env(:fake_docs_pages, pages)
  end

  @impl true
  def get(url) do
    case pages() |> Map.get(url, :not_a_page) do
      body when is_binary(body) -> {:ok, %{status: 200, body: body}}
      {status, body} when is_integer(status) -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
      :not_a_page -> {:ok, %{status: 404, body: "not found"}}
    end
  end

  defp pages, do: Application.get_env(:ex_tbp_monty, :fake_docs_pages, %{})
end
