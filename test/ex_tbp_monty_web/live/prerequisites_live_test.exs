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

  # "What is available here?" is the question the page is open for, so the
  # answer comes before the list of what has to be downloaded — and it names the
  # engine each world would step, not just "Python is installed".
  # The world card names the interpreter a run would use and nothing else: two
  # answers to "is MuJoCo here" is how a machine with MuJoCo came to read
  # "not available" first.
  test "the page names the interpreter the world runs in", %{conn: conn} do
    Tmp.system_env("MONTY_PYTHON", "/usr/bin/false")

    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert view |> element("#world-python") |> render() =~ "/usr/bin/false"
    refute has_element?(view, "#world-engines")
  end

  test "says a run cannot step its own world when no interpreter is configured", %{conn: conn} do
    Tmp.without_env("MONTY_PYTHON")

    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert view |> element("#world-python-warning") |> render() =~ "MONTY_PYTHON"
  end

  test "the page says which Python it carries, and where a run would report", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    # Not a download: part of the build, and the page says so rather than
    # leaving a run's loggers to fail quietly.
    assert has_element?(view, "#embedded-python")
    assert view |> element("#embedded-python-version") |> render() =~ "Python"
    assert view |> element("#embedded-python-wandb") |> render() =~ "wandb"
  end

  # The interpreter this build carries is where MuJoCo is installed
  # (`config/pythonx.exs`), so "is MuJoCo here?" must be asked of *it* — a page
  # that asks whatever `python3` the PATH offers reported a machine with MuJoCo
  # on it as one without.
  test "the embedded interpreter says which engines it can import", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert view |> element("#embedded-engine-mujoco") |> render() =~ "MuJoCo: installed"

    assert view |> element("#embedded-engine-habitat") |> render() =~
             "Habitat-Sim: not available here"
  end

  # A download that fills the disk is the failure this page exists to make
  # visible, so the room it writes into is answered before the click.
  test "the page says how much room is left where the downloads land", %{conn: conn, tmp: tmp} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert view |> element("#free-space") |> render() =~
             ~r/\d+(\.\d+)? (B|KiB|MiB|GiB|TiB) free of \d+(\.\d+)? (B|KiB|MiB|GiB|TiB) where they land \(#{Regex.escape(tmp)}/
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
