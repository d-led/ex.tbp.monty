defmodule ExTbpMonty.Mcp.RoadmapTest do
  # The roadmap is read from the same configured corpus as the docs.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Roadmap

  setup do
    previous = Application.get_env(:ex_tbp_monty, :monty_docs_dir)
    Application.put_env(:ex_tbp_monty, :monty_docs_dir, Path.expand("test/fixtures/mcp_docs"))
    on_exit(fn -> Application.put_env(:ex_tbp_monty, :monty_docs_dir, previous) end)
  end

  describe "the tasks" do
    test "are the pages under a section, with the metadata the project records" do
      assert [%{id: "clean-up-voting"}, %{id: "vote-on-state"} = task] = Roadmap.tasks()

      assert task.title == "Vote on state"
      assert task.section == "voting-improvements"
      assert task.status == "open"
      assert task.scope == "medium"
      assert task.output == "RFC"
      assert task.metric == "accuracy"
      assert task.online == "https://docs.thousandbrains.org/docs/vote-on-state"
    end

    test "are filtered by status" do
      assert [%{id: "vote-on-state"}] = Roadmap.tasks(status: "open")
      assert [%{id: "clean-up-voting"}] = Roadmap.tasks(status: "completed")
    end

    test "are filtered by a skill the task asks for" do
      assert [%{id: "vote-on-state"}] = Roadmap.tasks(skill: "monty-advanced")
    end

    test "are filtered by words the task contains" do
      assert [%{id: "vote-on-state"}] = Roadmap.tasks(query: "state identity")
      assert [] = Roadmap.tasks(query: "state quaternion")
    end
  end

  describe "one task" do
    test "is the whole page" do
      assert {:ok, task} = Roadmap.task("vote-on-state")
      assert task.body =~ "carry something about the state"
    end

    test "can be named by its path" do
      assert {:ok, %{id: "vote-on-state"}} =
               Roadmap.task("future-work/voting-improvements/vote-on-state.md")
    end

    test "is an error when there is no such task" do
      assert {:error, message} = Roadmap.task("no-such-task")
      assert message =~ "monty_roadmap"
    end
  end

  test "the sections name themselves and count their tasks" do
    assert [%{name: "voting-improvements", title: "Voting Improvements", tasks: 2}] =
             Roadmap.sections()
  end
end
