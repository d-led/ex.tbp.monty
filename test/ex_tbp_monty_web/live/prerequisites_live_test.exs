defmodule ExTbpMontyWeb.PrerequisitesLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Prerequisites
  alias Monty.Prerequisites.Download

  setup do
    tmp = Path.join(System.tmp_dir!(), "prereq-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    manifest = Path.join(tmp, "prerequisites.yaml")

    File.write!(manifest, """
    prerequisites:
      - id: tiny
        title: Tiny archive
        url: https://example.test/tiny.tgz
        root: MONTY_DATA
        target: tiny.tgz
    """)

    previous = System.get_env("MONTY_DATA")
    System.put_env("MONTY_DATA", Path.join(tmp, "data"))
    Application.put_env(:ex_tbp_monty, :prerequisites_manifest, manifest)
    Application.put_env(:ex_tbp_monty, :prerequisite_fetcher, Monty.Test.FakeFetcher)

    Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Download.topic())

    on_exit(fn ->
      if previous,
        do: System.put_env("MONTY_DATA", previous),
        else: System.delete_env("MONTY_DATA")

      Application.delete_env(:ex_tbp_monty, :prerequisites_manifest)
      Application.delete_env(:ex_tbp_monty, :prerequisite_fetcher)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "lists the prerequisite with its Monty target path", %{conn: conn, tmp: tmp} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert has_element?(view, "#prereq-tiny")
    assert render(view) =~ Path.join([tmp, "data", "tiny.tgz"])
    assert render(view) =~ "not downloaded"
  end

  test "a click downloads and the row reports the result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    view |> element("#download-tiny") |> render_click()

    assert_receive {:download, %{id: "tiny", status: :done}}, 1_000
    _ = :sys.get_state(view.pid)

    assert render(view) =~ "done"
    assert File.read!(Prerequisites.target_path(Prerequisites.get("tiny"))) == "hello world"
  end

  test "a prerequisite already on disk says so", %{conn: conn} do
    path = Prerequisites.target_path(Prerequisites.get("tiny"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "hello world")

    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert render(view) =~ "present"
  end
end
