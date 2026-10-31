defmodule ExTbpMontyWeb.RunHistoryLive.SelectionTest do
  use ExUnit.Case, async: true

  alias ExTbpMontyWeb.RunHistoryLive.Selection

  defp picked(ids), do: MapSet.new(ids)

  describe "picking rows" do
    test "a row that is not picked becomes picked" do
      assert Selection.handle("toggle", %{"id" => "a"}, %{selected: picked([])}) ==
               {:assign, selected: picked(["a"])}
    end

    test "a picked row is let go by picking it again" do
      assert Selection.handle("toggle", %{"id" => "a"}, %{selected: picked(["a", "b"])}) ==
               {:assign, selected: picked(["b"])}
    end

    test "clearing lets go of everything" do
      assert Selection.handle("clear_selection", %{}, %{selected: picked(["a", "b"])}) ==
               {:assign, selected: picked([])}
    end
  end

  describe "picking the page" do
    test "a page that is not picked is taken whole" do
      assigns = %{selected: picked(["far-away"]), page_ids: ["a", "b"]}

      assert Selection.handle("toggle_all", %{}, assigns) ==
               {:assign, selected: picked(["a", "b", "far-away"])}
    end

    test "a page that is already picked is let go" do
      assigns = %{selected: picked(["a", "b"]), page_ids: ["a", "b"]}

      assert Selection.handle("toggle_all", %{}, assigns) ==
               {:assign, selected: picked([])}
    end

    test "a partly picked page is taken, not emptied" do
      assigns = %{selected: picked(["a"]), page_ids: ["a", "b"]}

      assert Selection.handle("toggle_all", %{}, assigns) ==
               {:assign, selected: picked(["a", "b"])}
    end

    test "taking a page leaves runs picked elsewhere picked" do
      assigns = %{selected: picked(["a", "elsewhere"]), page_ids: ["a", "b"]}

      assert Selection.handle("toggle_all", %{}, assigns) ==
               {:assign, selected: picked(["a", "b", "elsewhere"])}
    end

    test "letting go a page leaves runs picked elsewhere picked" do
      assigns = %{selected: picked(["a", "b", "elsewhere"]), page_ids: ["a", "b"]}

      assert Selection.handle("toggle_all", %{}, assigns) ==
               {:assign, selected: picked(["elsewhere"])}
    end
  end

  describe "asking before deleting" do
    test "the picked rows are one question, with their number" do
      assigns = %{selected: picked(["a", "b"])}

      assert Selection.handle("ask_delete_selected", %{}, assigns) ==
               {:assign, confirming_bulk: %{count: 2, scope: {:ids, ["a", "b"]}}}
    end

    test "everything the filter shows is another, carrying the filter" do
      assigns = %{state: "failed", text: "base", total: 12}

      assert Selection.handle("ask_delete_matching", %{}, assigns) ==
               {:assign,
                confirming_bulk: %{
                  count: 12,
                  scope: {:matching, [state: "failed", text: "base"]}
                }}
    end

    test "the question can be taken back" do
      assert Selection.handle("cancel_bulk_delete", %{}, %{confirming_bulk: %{count: 2}}) ==
               {:assign, confirming_bulk: nil}
    end

    test "answering it forgets what the question was about" do
      assigns = %{confirming_bulk: %{count: 2, scope: {:ids, ["a", "b"]}}}

      assert Selection.handle("bulk_delete", %{}, assigns) == {:forget, {:ids, ["a", "b"]}}
    end
  end
end
