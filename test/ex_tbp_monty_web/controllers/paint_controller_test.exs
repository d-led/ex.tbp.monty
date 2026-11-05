defmodule ExTbpMontyWeb.PaintControllerTest do
  # The window mode is one environment variable for the whole VM, and the report
  # is one value in `:persistent_term`, so these cannot run beside another test
  # that asks the same question differently.
  use ExTbpMontyWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Monty.Test.Tmp

  setup do
    :persistent_term.erase({ExTbpMontyWeb.PaintController, :last})
    :ok
  end

  describe "a server that is a window's sidecar" do
    setup do
      Tmp.system_env("EX_TBP_MONTY_WINDOW", "1")
      :ok
    end

    test "keeps what the page sent, and answers it as lines", %{conn: conn} do
      answered =
        post(conn, ~p"/__painted", %{
          "path" => "/",
          "title" => "Monty on the BEAM",
          "heading" => "Monty, running on the BEAM.",
          "marks" => ["welcome-hero", "welcome-browse"]
        })

      assert answered.status == 204

      report = get(build_conn(), ~p"/__painted")

      assert report.status == 200
      assert report.resp_body =~ "path: /"
      assert report.resp_body =~ "title: Monty on the BEAM"
      assert report.resp_body =~ "heading: Monty, running on the BEAM."
      assert report.resp_body =~ "marks: welcome-hero,welcome-browse"
    end

    test "has nothing to answer until a page has drawn", %{conn: conn} do
      report = get(conn, ~p"/__painted")

      assert report.status == 404
      assert report.resp_body =~ "no page has reported what it drew"
    end

    test "takes the ids that are ids, and nothing else", %{conn: conn} do
      post(conn, ~p"/__painted", %{"marks" => ["fine-id", "<script>alert(1)", "", 42]})

      assert get(build_conn(), ~p"/__painted").resp_body =~ "marks: fine-id"
    end

    # The marker and its hook, not the whole tag: Phoenix expands the colocated
    # name to `ExTbpMontyWeb.Layouts.Painted`, and which of the two it writes is
    # its business.
    test "a page it shows carries the report", %{conn: conn} do
      {:ok, _view, page} = live(conn, ~p"/")

      assert page =~ ~s(id="painted")
      assert page =~ ~r/phx-hook="[^"]*Painted"/
    end
  end

  describe "a server that is not" do
    setup do
      Tmp.without_env("EX_TBP_MONTY_WINDOW")
      :ok
    end

    # A deployment has no window, and an endpoint that let a request write into a
    # server's memory is a worse thing than one nobody calls.
    test "has no such endpoint", %{conn: conn} do
      assert get(conn, ~p"/__painted").status == 404
      assert post(conn, ~p"/__painted", %{"heading" => "anything"}).status == 404
    end

    test "a page has nothing to report", %{conn: conn} do
      {:ok, _view, page} = live(conn, ~p"/")

      refute page =~ ~s(id="painted")
    end
  end
end
