defmodule Monty.Prerequisites.Fetcher do
  @moduledoc """
  Where bytes come from.

  A behaviour so the downloader can be tested without a network, and so a
  different transport (a conda mirror, an S3 client, a local cache) can be
  swapped in without touching the process that owns progress and atomicity.

  A fetcher writes nothing outside the path it is given and reports every
  chunk, which is what makes progress observable while a multi-gigabyte
  archive is arriving.
  """

  @doc """
  Downloads `url` into `path`, calling `on_chunk` with each chunk's size.

  `opts[:on_total]` is called with the content length when the server sends
  one. Returns the number of bytes written.
  """
  @callback download(
              url :: String.t(),
              path :: Path.t(),
              on_chunk :: (non_neg_integer() -> any()),
              opts :: keyword()
            ) :: {:ok, non_neg_integer()} | {:error, term()}
end
