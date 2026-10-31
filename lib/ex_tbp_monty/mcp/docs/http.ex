defmodule ExTbpMonty.Mcp.Docs.Http do
  @moduledoc """
  The one impure thing the documentation tools do: ask the published docs.

  Everything else in `ExTbpMonty.Mcp.Docs` is a reading of an answer — a URL
  built, a body parsed, a page split at its headings — so this is the seam a
  test replaces. `:docs_http` names the implementation, which is
  `ExTbpMonty.Mcp.Docs.Http.Req` unless a test says otherwise; a test that
  serves the bodies it expects specifies the ranking, the parsing and the
  wording without a network, and pins the URLs as the contract they are.

  A status is part of the answer rather than an error: a page the site has
  moved is a `404` a caller reports in words, not an exception. `{:error,
  reason}` is reserved for a request that never produced a response at all.
  """

  @type response :: %{status: non_neg_integer() | nil, body: binary()}

  @doc "GET a URL."
  @callback get(String.t()) :: {:ok, response()} | {:error, term()}
end
