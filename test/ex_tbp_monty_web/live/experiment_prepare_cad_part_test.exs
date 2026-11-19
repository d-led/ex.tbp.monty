defmodule ExTbpMontyWeb.ExperimentPrepareCadPartTest do
  @moduledoc """
  The click a CAD finding offers is answered on the page that names it.

  A CAD part's object set is written from the part file this node holds, so there
  is no archive to send a reader to: the click starts the build `/prerequisites`
  runs for that same directory, and the page says it started rather than leaving
  a button that did nothing.

  Sync, because the build reads the roots the machine has: a test that pointed
  them at a temporary tree while another test wrote the real one would be a race.
  """

  use ExTbpMontyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Monty.Prerequisites
  alias Monty.Prerequisites.Saga
  alias Monty.Test.PrerequisiteRoots
  alias Monty.Test.Tmp

  # An experiment of a CAD part with the whole of its object set missing, which
  # is the state the finding names.
  @experiment "cad/plate_features_2patch_eval"

  setup do
    # The folder first, the build's stop second: the callbacks run in reverse,
    # so the build is stopped before the folder it writes into is removed.
    root = Tmp.dir("prepare-cad-part")
    on_exit(&stop_build/0)

    {:ok, root: root}
  end

  test "the page starts the build its finding names", %{conn: conn, root: root} do
    PrerequisiteRoots.with_roots(root, fn ->
      {:ok, view, _html} = live(conn, ~p"/experiments/#{@experiment}")

      assert render_click(view, "prepare_cad_part") =~ "is writing the object sets"

      assert Saga.lookup("cad_part_memories"),
             "the machine the prerequisite row starts for the same directory"
    end)
  end

  # A memory on disk taught from other optics is the finding that puts this
  # button on the page, and its own directory is present — so a click the
  # prerequisite's presence check answers would leave the memory as it was and
  # the finding on the page.
  test "the page asks for the build where the memories are already there", %{
    conn: conn,
    root: root
  } do
    PrerequisiteRoots.with_roots(root, fn ->
      where_the_memories_are()
      fake_build(["the plate"])
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Saga.topic())

      {:ok, view, _html} = live(conn, ~p"/experiments/#{@experiment}")
      render_click(view, "prepare_cad_part")

      assert_receive {:download, %{id: "cad_part_memories", status: :building}}, 2_000
    end)
  end

  # Everything `Monty.Prerequisites.present?/1` asks of this build: a file per
  # memory it promises, in the folder it fills, and something in every other
  # place it writes.
  defp where_the_memories_are do
    prerequisite = Prerequisites.get("cad_part_memories")

    for path <- Prerequisites.promised_memories(prerequisite) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
    end

    for landing <- Prerequisites.landings(prerequisite) do
      File.mkdir_p!(landing)
      File.write!(Path.join(landing, "kept"), "")
    end

    assert Prerequisites.present?(prerequisite), "a build that is already there"
  end

  defp fake_build(steps) do
    Application.put_env(:ex_tbp_monty, :prerequisite_builder, Monty.Test.FakeBuilder)
    Application.put_env(:ex_tbp_monty, :fake_build_steps, steps)

    on_exit(fn ->
      Application.delete_env(:ex_tbp_monty, :prerequisite_builder)
      Application.delete_env(:ex_tbp_monty, :fake_build_steps)
    end)
  end

  # A build is minutes of this machine's work and the assertion is that it
  # started, so the test stops it rather than paying for it.
  defp stop_build do
    case Saga.lookup("cad_part_memories") do
      nil -> :ok
      server -> Saga.cancel(server)
    end
  end
end
