defmodule ExTbpMontyWeb.PageController do
  use ExTbpMontyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
