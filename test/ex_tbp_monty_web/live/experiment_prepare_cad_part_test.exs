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

  # A build is minutes of this machine's work and the assertion is that it
  # started, so the test stops it rather than paying for it.
  defp stop_build do
    case Saga.lookup("cad_part_memories") do
      nil -> :ok
      server -> Saga.cancel(server)
    end
  end
end
