defmodule ExTbpMontyWeb.PrerequisitesLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Prerequisites
  alias Monty.Prerequisites.Download
  alias Monty.Test.Tmp

  setup do
    tmp = Tmp.dir("prereq-live")
    manifest = Path.join(tmp, "prerequisites.yaml")

    File.write!(manifest, """
    prerequisites:
      - id: tiny
        title: Tiny archive
        url: https://example.test/tiny.tgz
        root: MONTY_DATA
        target: tiny.tgz
    """)

    Tmp.system_env("MONTY_DATA", Path.join(tmp, "data"))
    Tmp.app_env(:prerequisites_manifest, manifest)
    Tmp.app_env(:prerequisite_fetcher, Monty.Test.FakeFetcher)

    Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Download.topic())

    on_exit(fn -> Monty.Test.PrerequisiteDownloads.stop_all() end)

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

  test "a folder that cannot be created is a message, not a crash", %{conn: conn, tmp: tmp} do
    # A file where the folder should be: the click fails at the click, with the
    # path in the message, and the page stays up.
    blocker = Path.join(tmp, "blocker")
    File.write!(blocker, "not a directory")
    System.put_env("MONTY_DATA", Path.join(blocker, "data"))

    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert view |> element("#download-tiny") |> render_click() =~ "Cannot create"
    assert has_element?(view, "#prereq-tiny")
  end

  test "a prerequisite already on disk says so", %{conn: conn} do
    path = Prerequisites.target_path(Prerequisites.get("tiny"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "hello world")

    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert render(view) =~ "present"
  end
end
