defmodule Monty.Studio.SystemTest do
  @moduledoc """
  What the settings page shows about the instance, and why each row is there.

  These are the facts a desktop user is asked to send back when a run is slower
  than it should be — and every one of them has been guessed at wrongly at least
  once: whether the Rust kernels are loaded, whether the writes land in a file on
  this machine at all, and what the machine is.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.System

  test "every fact has something to say" do
    facts = System.facts()

    assert Enum.all?(facts, &(is_binary(&1.label) and &1.label != ""))
    assert Enum.all?(facts, &(is_binary(&1.value) and &1.value != ""))
  end

  test "the facts a report needs are all there" do
    labels = System.facts() |> Enum.map(& &1.label)

    assert "Kernels" in labels
    assert "Database file" in labels
    assert "Data directory" in labels
    assert "Machine" in labels
  end

  test "the kernels are named as either the Rust ones or the Elixir paths" do
    assert %{value: value} = Enum.find(System.facts(), &(&1.label == "Kernels"))

    assert value in ["native (Rust)", "Elixir reference paths"],
           "a reader has to be able to tell which arithmetic ran: #{inspect(value)}"
  end

  test "the database's row says where a run's writes land" do
    assert %{value: value} = Enum.find(System.facts(), &(&1.label == "Database file"))

    # A SQLite instance names its file and how that file journals, because WAL is
    # what lets a page read while a run writes; a server instance says that its
    # rows are not a file here — not that nothing is written locally, since the
    # run's pictures and transcript always are.
    assert value =~ "journal:" or value =~ "the rows are not a file here",
           "the row has to say where the rows go: #{inspect(value)}"
  end

  test "the machine's row names its architecture, its schedulers and its memory" do
    assert %{value: value} = Enum.find(System.facts(), &(&1.label == "Machine"))

    assert value =~ "schedulers"
    assert value =~ ~r/(aarch64|arm|x86_64)/, "the architecture is what separates the machines"
  end
end
