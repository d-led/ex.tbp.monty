defmodule ExTbpMontyWeb.PrerequisitesLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Prerequisites
  alias Monty.Prerequisites.Saga
  alias Monty.Test.Tmp

  setup do
    tmp = Tmp.dir("prereq-live")
    manifest = Path.join(tmp, "prerequisites.yaml")

    File.write!(manifest, """
    prerequisites:
      - id: tiny
        title: Tiny archive
        url: https://example.test/tiny.tgz
        sha256: b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
        upstream: the test manifest
        licence: MIT
        root: MONTY_DATA
        target: tiny.tgz
      - id: made_here
        title: Something this application makes
        root: MONTY_LIBRARIES
        target: made-here
        unpacks_to: made-here
        build: cad_part_memories
        provides:
          - one
          - two
    """)

    Tmp.system_env("MONTY_DATA", Path.join(tmp, "data"))
    # A build that writes memories writes them where a run reads them: the
    # libraries, which is also the pin the application keeps, so a test that
    # moved only the variable would write into the build's own `priv/`.
    Tmp.system_env("MONTY_LIBRARIES", Path.join(tmp, "libraries"))
    Tmp.app_env(:monty_libraries_dir, Path.join(tmp, "libraries"))
    Tmp.app_env(:prerequisites_manifest, manifest)
    Tmp.app_env(:prerequisite_fetcher, Monty.Test.FakeFetcher)

    Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Saga.topic())

    on_exit(fn -> Monty.Test.PrerequisiteDownloads.stop_all() end)

    {:ok, tmp: tmp}
  end

  test "lists the prerequisite with its Monty target path", %{conn: conn, tmp: tmp} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert has_element?(view, "#prereq-tiny")
    assert render(view) =~ Path.join([tmp, "data", "tiny.tgz"])
    assert render(view) =~ "not downloaded"
  end

  # The row says what a person agreeing to a download is agreeing to: whose
  # archive it is, on what terms, and the bytes it should turn out to be. It
  # reads all three off the manifest, so the page cannot promise something the
  # fetch does not check.
  # An entry this application makes instead of downloading gets the click that
  # makes it, rather than one that asks the network for it.
  test "an entry this application makes offers the click that makes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert has_element?(view, "#build-made_here[phx-click=\"build\"]")
    refute has_element?(view, "#download-made_here")
  end

  # A build is not an archive: what is on the disk is what Make wrote, and the
  # row that called that "unpacked" was describing an unpacking nobody did. It
  # also says which of the memories it promised are not there, because a
  # directory with half a build in it answers no run of the other half.
  test "a build says what it wrote, and which of its memories are missing", %{conn: conn} do
    target = Prerequisites.target_path(Prerequisites.get("made_here"))
    File.mkdir_p!(target)
    File.write!(Path.join(target, "one.jsonl.gz"), String.duplicate("a", 2048))

    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    # The sizes are measured beside the page rather than while it is drawn, so the
    # row says "measuring…" until that answer lands.
    render_async(view)

    assert view |> element("#size-made_here") |> render() =~ ~r/2\.0 KiB written/
    refute view |> element("#size-made_here") |> render() =~ "unpacked"

    assert view |> element("#missing-made_here") |> render() =~ "not written yet: two"

    # The directory is there and a memory a configuration names is not: "present"
    # was a badge that disagreed with the run page saying no memory can be read.
    assert view |> element("#prereq-made_here") |> render() =~ "partly built"
  end

  test "a build that wrote everything it promises is present", %{conn: conn} do
    target = Prerequisites.target_path(Prerequisites.get("made_here"))
    File.mkdir_p!(target)

    for name <- ["one", "two"], do: File.write!(Path.join(target, "#{name}.jsonl.gz"), "x")

    {:ok, view, _html} = live(conn, ~p"/prerequisites")
    render_async(view)

    assert view |> element("#prereq-made_here") |> render() =~ "present"
    refute has_element?(view, "#missing-made_here")
  end

  test "says where an archive comes from, on what terms, and which bytes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    provenance = view |> element("#provenance-tiny") |> render()

    assert provenance =~ "MIT"
    assert provenance =~ "sha256 b94d27b9…"
    assert provenance =~ "the test manifest"
  end

  # A finding that says a run is waiting for an archive offers the click, and the
  # click is a URL: arriving with `?fetch=` starts that download, so the link a
  # reader follows is the download rather than a page to hunt on.
  describe "arriving with a prerequisite named" do
    test "starts that download", %{conn: conn} do
      assert Saga.lookup("tiny") == nil

      {:ok, _view, _html} = live(conn, ~p"/prerequisites?fetch=tiny")

      assert Saga.lookup("tiny") != nil
    end

    test "says so when the name is not one of the manifest's", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prerequisites?fetch=nonesuch")

      assert render(view) =~ "Unknown prerequisite"
      assert Saga.lookup("nonesuch") == nil
    end

    test "does not start an archive that is already here", %{conn: conn, tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "data"))
      File.write!(Path.join([tmp, "data", "tiny.tgz"]), "already here")

      {:ok, _view, _html} = live(conn, ~p"/prerequisites?fetch=tiny")

      assert Saga.lookup("tiny") == nil
    end
  end

  # Reading the memory out of an archive's pickles has no bytes to count, so the
  # row says which model the exporter is on and how many there are — otherwise
  # the badge says "reading memory" for minutes and looks stuck.
  test "says which model it is reading while it reads the memory", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    Phoenix.PubSub.broadcast(
      ExTbpMonty.PubSub,
      Saga.topic(),
      {:download,
       %{
         id: "tiny",
         status: :exporting,
         bytes: 10,
         total: 10,
         export: %{
           model: "pretrained_ycb_v10/surf_agent_1lm_10distinctobj",
           index: 2,
           total: 5
         },
         libraries: nil
       }}
    )

    reading = view |> element("#reading-tiny") |> render()

    assert reading =~ "reading memory 2/5"
    assert reading =~ "pretrained_ycb_v10/surf_agent_1lm_10distinctobj"
  end

  # The state a restored volume is in: the archive is unpacked and the memory a
  # run reads was never exported. Saying "present" here is the page saying a run
  # can go, and the first step answering that there is no memory.
  describe "an archive whose memory was never read" do
    setup %{tmp: tmp} do
      manifest = Path.join(tmp, "bundles.yaml")

      File.write!(manifest, """
      prerequisites:
        - id: bundles
          title: Pretrained models
          url: https://example.test/models.tgz
          root: MONTY_MODELS
          target: models.tgz
          extract: true
      """)

      Tmp.system_env("MONTY_MODELS", Path.join(tmp, "models"))
      Tmp.app_env(:monty_libraries_dir, Path.join(tmp, "libraries"))
      Tmp.app_env(:prerequisites_manifest, manifest)

      land = Prerequisites.where_it_lands(Prerequisites.get("bundles", manifest))
      pickle = Path.join([land, "pretrained_ycb_v14", "mug", "pretrained", "model.pt"])
      File.mkdir_p!(Path.dirname(pickle))
      File.write!(pickle, "not a torch save")

      {:ok, land: land}
    end

    test "says so, and offers to read it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prerequisites")

      assert render(view) =~ "memory not read"
      assert view |> element("#download-bundles") |> render() =~ "Export memory"
    end

    test "has nothing to offer once its libraries are here", %{conn: conn, land: land} do
      library = Monty.Studio.Memory.path_for("mug", "pretrained_ycb_v14")
      File.mkdir_p!(Path.dirname(library))
      File.write!(library, "")

      {:ok, view, _html} = live(conn, ~p"/prerequisites")

      refute has_element?(view, "#download-bundles")
      assert render(view) =~ "present"
      assert land =~ "models"
    end

    # The row that made a person ask "and when, then?": the archive was here
    # and its memories were not, so it wore a green "present" badge over a list
    # that said none of the models had been written — with no click between
    # them. One rule now answers both (the run's own, `absent_memories/1`), so
    # the badge says what is true and the button beside it is the work.
    test "says its memory is not read when the models it promises are missing", %{
      conn: conn,
      tmp: tmp
    } do
      manifest = Path.join(tmp, "provided.yaml")

      File.write!(manifest, """
      prerequisites:
        - id: cows
          title: Compositional models
          url: https://example.test/cows.tgz
          root: MONTY_MODELS
          target: cows.tgz
          extract: true
          unpacks_to: pretrained_compositional_objects_v13
          provides:
            - supervised_pre_training_cows_small_compositional
      """)

      Tmp.app_env(:prerequisites_manifest, manifest)

      land = Prerequisites.where_it_lands(Prerequisites.get("cows", manifest))

      pickle =
        Path.join([
          land,
          "supervised_pre_training_cows_small_compositional",
          "pretrained",
          "model.pt"
        ])

      File.mkdir_p!(Path.dirname(pickle))
      File.write!(pickle, "not a torch save")

      {:ok, view, _html} = live(conn, ~p"/prerequisites")

      assert view |> element("#prereq-cows") |> render() =~ "memory not read"
      assert view |> element("#download-cows") |> render() =~ "Export memory"
      refute has_element?(view, "#missing-cows")
    end
  end

  # "What is available here?" is the question the page is open for, so the
  # answer comes before the list of what has to be downloaded — and it names the
  # engine each world would step, not just "Python is installed".
  # One interpreter, and it is this application's own: a page that printed a
  # PATH `python3` read as "here is what your runs use", which was never true.
  test "the page names the interpreter the world runs in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert view |> element("#world-python") |> render() =~ "own interpreter"
    refute has_element?(view, "#world-python-warning")
  end

  # The interpreter this build carries is where MuJoCo is installed
  # (`config/pythonx.exs`), so "is MuJoCo here?" must be asked of *it* — a page
  # that asks whatever `python3` the PATH offers reported a machine with MuJoCo
  # on it as one without.
  test "the embedded interpreter says which engines it can import", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert view |> element("#embedded-engine-mujoco") |> render() =~ "MuJoCo: installed"
  end

  # A walk of a bundle's directory is thousands of files on a prepared machine, so
  # the page does not take it while it is drawn: the answer to a request says
  # "measuring…" and the number arrives when the walk does. This is what the
  # request-log test timed out inside, on a busy disk.
  test "the page answers before the sizes are measured", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/prerequisites")

    assert html =~ "measuring…"
    refute html =~ "nothing on disk yet"

    render_async(view)
    refute view |> element("#size-tiny") |> render() =~ "measuring…"
  end

  # A download that fills the disk is the failure this page exists to make
  # visible, so the room it writes into is answered before the click.
  test "the page says how much room is left where the downloads land", %{conn: conn, tmp: tmp} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    # The room is answered by the page itself — one `df` per root — because it is
    # what a person needs before starting a download that has to fit: a page that
    # said it only once a walk of the directories had finished said nothing to
    # anybody reading the HTML.
    assert view |> element("#free-space-volume") |> render() =~
             ~r/\d+(\.\d+)? (B|KiB|MiB|GiB|TiB) free of \d+(\.\d+)? (B|KiB|MiB|GiB|TiB) on \S+, \d+% used/

    # And the walk runs beside the page: `render_async/1` waits for its answer,
    # which is the rest of the state a reader waits for before clicking. An empty
    # directory is measured before a test can look at the in-flight wording, so
    # what is asserted is where the numbers end up.
    render_async(view)

    assert view |> element("#occupied-MONTY_DATA") |> render() =~
             "nothing in #{Path.join(tmp, "data")} yet"
  end

  # The header's figure belongs to the directory, not to the rows. A root holds
  # releases this page does not list, and a reader who reads its total as "what
  # the entries below cost" is owed the sentence that says so.
  test "the page says what the directory the downloads land in already holds", %{
    conn: conn,
    tmp: tmp
  } do
    data = Path.join(tmp, "data")
    File.mkdir_p!(data)
    File.write!(Path.join(data, "an-older-release.tgz"), :binary.copy("x", 2048))

    {:ok, view, _html} = live(conn, ~p"/prerequisites")
    render_async(view)
    occupied = view |> element("#occupied-MONTY_DATA") |> render()

    assert occupied =~ "2.0 KiB in #{data}"
    assert occupied =~ "not only the entries below"
  end

  test "a click downloads, and the row then says what is on the disk", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    view |> element("#download-tiny") |> render_click()

    assert_receive {:download, %{id: "tiny", status: :done}}, 1_000
    _ = :sys.get_state(view.pid)

    # A finished fetch is a bundle, not a download: the row re-reads the disk, so
    # it says "present" and how big the thing is. "done" on a machine that has
    # ended was a badge that only changed on the next visit.
    assert view |> element("#prereq-tiny") |> render() =~ "present"
    assert view |> element("#size-tiny") |> render() =~ ~r/11 B archive/
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

  # An archive whose bytes arrived and whose unpack did not: the row that called
  # that "not downloaded" was asking a person to wait for a file already on the
  # disk. What is left is the unpack, and the click says so.
  test "an archive whose bytes arrived and are not unpacked says which work is left", %{
    conn: conn,
    tmp: tmp
  } do
    manifest = Path.join(tmp, "arrived.yaml")

    File.write!(manifest, """
    prerequisites:
      - id: arrived
        title: Arrived archive
        url: https://example.test/arrived.tgz
        root: MONTY_DATA
        target: arrived.tgz
        extract: true
        unpacks_to: arrived
    """)

    Tmp.app_env(:prerequisites_manifest, manifest)

    path = Prerequisites.target_path(Prerequisites.get("arrived", manifest))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "the bytes were fetched")

    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert view |> element("#prereq-arrived") |> render() =~ "not unpacked"
    assert view |> element("#download-arrived") |> render() =~ "Unpack"
  end

  # The finding on an experiment page says the memory is missing and links here.
  # The row used to answer "present" — the release holds a memory, so the
  # directory is not empty — and started nothing, which left a first-time part
  # with no click anywhere. Whether a build has work to do is what its plans say.
  test "a build whose release holds a memory still offers the click its missing one needs",
       %{conn: conn} do
    real = Path.join(to_string(:code.priv_dir(:ex_tbp_monty)), "prerequisites.yaml")
    Tmp.app_env(:prerequisites_manifest, real)

    libraries = Application.fetch_env!(:ex_tbp_monty, :monty_libraries_dir)
    File.mkdir_p!(Path.join(libraries, "cad_parts_v1"))

    File.write!(
      Path.join([libraries, "cad_parts_v1", "plate_part.jsonl.gz"]),
      "a memory that is here"
    )

    assert {:ok, _generated} = Monty.Studio.Cad.Generate.generate("solidcraft-plate")

    {:ok, view, _html} = live(conn, ~p"/prerequisites")
    # The shipped manifest is the real one, so the page's measuring task walks
    # every archive's size — a slower answer than the fixture manifest's.
    html = render_async(view, 10_000)

    assert html =~ "present"
    assert has_element?(view, "#build-cad_part_memories")
  end

  # And the click does what it says. `Saga.start/1` takes the presence path when
  # the target holds anything, so the row's Make wrote nothing at all — the same
  # defect the experiment page's own click was fixed for.
  test "and its click starts the build rather than seeing a present folder",
       %{conn: conn} do
    real = Path.join(to_string(:code.priv_dir(:ex_tbp_monty)), "prerequisites.yaml")
    Tmp.app_env(:prerequisites_manifest, real)
    Tmp.app_env(:prerequisite_builder, Monty.Test.FakeBuilder)
    Tmp.app_env(:fake_build_steps, ["the plate"])
    on_exit(fn -> Application.delete_env(:ex_tbp_monty, :prerequisite_builder) end)

    libraries = Application.fetch_env!(:ex_tbp_monty, :monty_libraries_dir)
    File.mkdir_p!(Path.join(libraries, "cad_parts_v1"))

    File.write!(
      Path.join([libraries, "cad_parts_v1", "plate_part.jsonl.gz"]),
      "a memory that is here"
    )

    Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Monty.Prerequisites.Saga.topic())

    assert {:ok, view, _html} = live(conn, ~p"/prerequisites")
    render_async(view, 10_000)

    view |> element("#build-cad_part_memories") |> render_click()

    assert_receive {:download, %{id: "cad_part_memories", status: :building}}, 2_000

    on_exit(fn ->
      case Monty.Prerequisites.Saga.lookup("cad_part_memories") do
        nil -> :ok
        server -> Monty.Prerequisites.Saga.cancel(server)
      end
    end)
  end

  # A part a person brings is planned by the same click and cannot be promised by
  # the manifest, which is written before the part exists. The row names it, or
  # the CAD page's sentence — "the row teaches <part>_part" — is about a page that
  # never says so.
  test "a build names the part a person brought, which its promises cannot",
       %{conn: conn} do
    assert {:ok, _generated} = Monty.Studio.Cad.Generate.generate("solidcraft-plate")

    {:ok, view, _html} = live(conn, ~p"/prerequisites")

    assert render_async(view) =~ "solidcraft-plate_part"
  end

  # And it names it after the Make as well. The row read "present" and said
  # nothing else once the memory was written, so the only sentence that ever
  # mentioned a brought part disappeared exactly when the part was there — the
  # badge answering "is there anything to do?" and never "is mine in there?".
  test "and names it after its memory is written, when no click is left",
       %{conn: conn} do
    assert {:ok, _generated} = Monty.Studio.Cad.Generate.generate("solidcraft-plate")

    libraries = Application.fetch_env!(:ex_tbp_monty, :monty_libraries_dir)
    written = Path.join([libraries, "cad_parts_v1", "solidcraft-plate_part.jsonl.gz"])
    File.mkdir_p!(Path.dirname(written))
    File.write!(written, "a memory that is here")

    {:ok, view, _html} = live(conn, ~p"/prerequisites")
    render_async(view, 10_000)

    assert view |> element("#also-made_here") |> render() =~ "written by the same Make"
  end
end
