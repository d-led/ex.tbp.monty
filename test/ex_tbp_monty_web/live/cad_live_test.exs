defmodule ExTbpMontyWeb.CadLiveTest do
  @moduledoc """
  The CAD page: a file goes in, a part comes out, and the two clicks that make it
  a run are on the page that made it.

  The upload cases drive the real form (`file_input/4` and `render_upload/2`), so
  what is proved is what a person does — a browser posting a file to this page —
  and the recognition asserted on the page is quiddity's, about the part the
  application ships.
  """

  use ExTbpMontyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Monty.Studio.Cad.Parts
  alias Monty.Test.Tmp

  setup do
    data = Tmp.dir("cad-live")
    Tmp.system_env("MONTY_DATA", data)
    Tmp.system_env("MONTY_LIBRARIES", Path.join(data, "libraries"))
    Tmp.app_env(:monty_libraries_dir, Path.join(data, "libraries"))

    {:ok, sets: Tmp.env_dir("cad-live-sets", :cad_sets_dir), step: shipped_step()}
  end

  defp shipped_step do
    File.read!(
      Path.join(
        Path.join(to_string(:code.priv_dir(:ex_tbp_monty)), "cad_experiments/parts"),
        "solidcraft-plate.step"
      )
    )
  end

  defp bring(view, name, content) do
    upload =
      file_input(view, "#cad-bring-form", :step, [
        %{name: "#{name}.step", content: content, type: "application/octet-stream"}
      ])

    render_upload(upload, "#{name}.step")
    view |> element("#cad-bring-form") |> render_submit(%{"bring" => %{"name" => name}})
  end

  describe "the parts this machine has" do
    test "are on the page, with the way to bring another", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/cad")

      assert html =~ "solidcraft-plate"
      assert has_element?(view, "#cad-bring-form")
      assert has_element?(view, "#cad-bring-form input[type=file]")
    end

    test "and the page is one of the studio's sections", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cad")

      assert has_element?(view, "#nav-cad")
    end
  end

  describe "bringing a part" do
    test "the page lists it with the recognition's own numbers", %{conn: conn, step: step} do
      {:ok, view, _html} = live(conn, ~p"/cad")

      html = bring(view, "brought_plate", step)

      assert html =~ "brought_plate"
      # quiddity's answer about the same part under its old name: the page shows
      # what the recognition found, not a guess.
      assert html =~ "80 × 50 × 22"
      assert html =~ "fillets"
    end

    test "a file that is not a part is refused, and the page says why", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cad")

      html = bring(view, "not_a_part", "this is not STEP")

      assert html =~ "could not be read as a STEP part"
      refute Enum.any?(Parts.list(), &(&1.name == "not_a_part"))
    end
  end

  describe "making a part a run" do
    test "writes its experiment and says what to click next", %{conn: conn, sets: sets} do
      {:ok, view, _html} = live(conn, ~p"/cad")

      html = view |> element("#generate-solidcraft-plate") |> render_click()

      assert html =~ "cad/solidcraft-plate_part_eval"
      assert has_element?(view, "#generated a[href='/prerequisites']")

      assert has_element?(
               view,
               "#generated a[href='/experiments/cad/solidcraft-plate_part_eval']"
             )

      assert File.exists?(
               Path.join([sets, "brought/conf/experiment/cad/solidcraft-plate_part_eval.yaml"])
             )
    end

    test "twice is the same experiment, not a second one", %{conn: conn, sets: sets} do
      {:ok, view, _html} = live(conn, ~p"/cad")

      view |> element("#generate-solidcraft-plate") |> render_click()
      html = view |> element("#generate-solidcraft-plate") |> render_click()

      assert html =~ "cad/solidcraft-plate_part_eval"

      assert Path.wildcard(Path.join([sets, "brought/conf/experiment/cad/*.yaml"]))
             |> length() == 1
    end
  end
end
