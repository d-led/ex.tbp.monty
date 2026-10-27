defmodule Monty.Test.FixtureServer do
  @moduledoc "A tiny HTTP server for testing the real fetcher without the network."

  use Plug.Router

  plug :match
  plug :dispatch

  get "/tiny.tgz" do
    conn
    |> put_resp_header("content-type", "application/octet-stream")
    |> send_resp(200, "hello world")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
