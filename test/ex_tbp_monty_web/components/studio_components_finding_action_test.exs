defmodule ExTbpMontyWeb.StudioComponents.FindingActionTest do
  @moduledoc """
  What a check draws when the fix is on this page rather than another one.

  A finding that names work this node does itself — writing a CAD part's object
  set from the part file it holds — carries an event, and the page answers it. A
  finding whose fix is somewhere else carries a link. Drawing the wrong one is a
  reader clicking nothing (an `href` of `nil`) or leaving the page for work that
  was here.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ExTbpMontyWeb.StudioComponents
  alias Monty.Studio.Finding

  test "a finding this page can act on draws the button that names its event" do
    html =
      draw(
        :error
        |> Finding.new(:world_data_missing, "Not on this machine yet: cad_objects.")
        |> Finding.with_action("Prepare cad_objects", "prepare_cad_part")
      )

    assert html =~ ~s(id="finding-world_data_missing-0-do")
    assert html =~ ~s(phx-click="prepare_cad_part")
    assert html =~ "Prepare cad_objects"
    refute html =~ "<a"
  end

  test "a finding whose fix is another page still draws the link" do
    html =
      :error
      |> Finding.new(:world_data_missing, "Not on this machine yet: objects.")
      |> Finding.with_link("Download it", "/prerequisites?fetch=objects")
      |> draw()

    assert html =~ ~s(href="/prerequisites?fetch=objects")
    assert html =~ "Download it"
    refute html =~ "<button"
  end

  defp draw(finding), do: render_component(&StudioComponents.findings/1, %{findings: [finding]})
end
