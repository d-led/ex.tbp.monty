defmodule ExTbpMontyWeb.HealthControllerTest do
  # What a monitor acts on, and what the desktop's boot check reads: the answer
  # names the node that gave it, because a page served by one of several is a page
  # whose reader has to know which.
  use ExTbpMontyWeb.ConnCase, async: true

  test "says it is up, and which node answered", %{conn: conn} do
    answer = conn |> get(~p"/health") |> json_response(200)

    assert answer["status"] == "ok"
    assert answer["node"] == ExTbpMonty.Node.address(node())
  end
end
