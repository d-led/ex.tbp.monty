defmodule ExTbpMonty.Mcp.Tools.RoadmapTest do
  # The roadmap is read from the same configured corpus as the docs.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Tools.Roadmap

  setup do
    previous = Application.get_env(:ex_tbp_monty, :monty_docs_dir)
    Application.put_env(:ex_tbp_monty, :monty_docs_dir, Path.expand("test/fixtures/mcp_docs"))
    on_exit(fn -> Application.put_env(:ex_tbp_monty, :monty_docs_dir, previous) end)
  end

  describe "monty_roadmap" do
    test "lists the tasks, and counts them all even when it shows fewer" do
      assert {:ok, %{text: text, structured: %{count: 2, tasks: tasks}}} = Roadmap.tasks(%{}, %{})

      assert length(tasks) == 2
      assert text =~ "vote-on-state"
    end

    test "says how many more there are when the limit cuts the list" do
      assert {:ok, %{text: text, structured: %{count: 2, tasks: tasks}}} =
               Roadmap.tasks(%{"limit" => 1}, %{})

      assert length(tasks) == 1
      assert text =~ "1 more; raise `limit`"
    end

    test "names the sections when nothing matches" do
      assert {:ok, %{text: text, structured: %{count: 0, tasks: []}}} =
               Roadmap.tasks(%{"query" => "aardvark"}, %{})

      assert text =~ "No task matches"
      assert text =~ "voting-improvements"
    end

    test "refuses a limit that is not a number" do
      assert Roadmap.tasks(%{"limit" => "many"}, %{}) ==
               {:error, "`limit` must be an integer."}
    end
  end

  describe "monty_roadmap_task" do
    test "gives the whole task, with its body as markdown" do
      assert {:ok, %{text: text, structured: task}} =
               Roadmap.task(%{"task" => "vote-on-state"}, %{})

      assert task.id == "vote-on-state"
      assert is_binary(task.markdown)
      refute Map.has_key?(task, :body)
      assert text =~ "# Vote on state"
    end

    test "asks for the task it needs" do
      assert Roadmap.task(%{}, %{}) == {:error, "`task` is required."}
    end

    test "says so when there is no such task" do
      assert {:error, message} = Roadmap.task(%{"task" => "no-such-task"}, %{})
      assert message =~ "no-such-task"
    end
  end
end
