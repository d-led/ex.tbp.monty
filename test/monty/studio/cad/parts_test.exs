defmodule Monty.Studio.Cad.PartsTest do
  @moduledoc """
  The STEP parts a person can bring to a run, and the place the worlds look.

  These cases are about the boundary a file crosses: which name it may take,
  what happens to a name that is already taken, and that a file which is not a
  part is refused *before* it becomes one. The recognition's own numbers are
  asserted on a part the application ships, so the describe case has ground
  truth that is not this module's opinion.
  """

  use ExUnit.Case, async: false

  alias Monty.Studio.Cad.Parts
  alias Monty.Test.Tmp

  setup do
    data = Tmp.dir("cad-parts")
    Tmp.system_env("MONTY_DATA", data)

    {:ok, parts_dir: Path.join(data, "parts"), shipped: shipped_bytes()}
  end

  defp shipped(name) do
    Path.join(Path.join(to_string(:code.priv_dir(:ex_tbp_monty)), "cad_experiments/parts"), name)
  end

  defp shipped_bytes, do: File.read!(shipped("solidcraft-plate.step"))

  describe "what this machine has" do
    test "the parts the application ships are the ones a person can choose" do
      names = Parts.list() |> Enum.map(& &1.name)

      assert "solidcraft-plate" in names
      assert "plate" in names
    end

    test "a part brought here is listed beside the ones that ship", %{shipped: bytes} do
      assert {:ok, part} = Parts.install("brought_plate", bytes)

      listed = Parts.list()
      assert part in listed
      assert Enum.map(listed, & &1.name) |> Enum.count(&(&1 == "brought_plate")) == 1
    end
  end

  describe "bringing a part" do
    test "the file's bytes become a part the worlds look for", %{parts_dir: dir, shipped: bytes} do
      assert {:ok, part} = Parts.install("brought_plate", bytes)

      assert part.name == "brought_plate"
      assert part.path == Path.join(dir, "brought_plate.step")
      assert File.read!(part.path) == bytes
    end

    test "a part already here with the same bytes is not written twice", %{shipped: bytes} do
      assert {:ok, first} = Parts.install("brought_plate", bytes)
      # A file that is left alone keeps the time it was given; one that was
      # rewritten would carry the time of the second install.
      File.touch!(first.path, {{2000, 1, 1}, {0, 0, 0}})

      assert {:ok, second} = Parts.install("brought_plate", bytes)

      assert first.path == second.path
      assert File.stat!(first.path).mtime == {{2000, 1, 1}, {0, 0, 0}}
    end

    # A memory is taught from these bytes, so overwriting them silently would
    # leave every memory of this part describing a file that is no longer it.
    test "a part already here with other bytes is refused, and the file is left alone",
         %{shipped: bytes} do
      assert {:ok, part} = Parts.install("brought_plate", bytes)

      assert {:error, sentence} = Parts.install("brought_plate", "ISO-10303-21; other")
      assert sentence =~ "already a part"
      assert File.read!(part.path) == bytes
    end

    test "a file that is not a part is refused and leaves nothing behind", %{parts_dir: dir} do
      assert {:error, sentence} = Parts.install("not_a_part", "this is not STEP")
      assert sentence =~ "could not be read as a STEP part"

      assert File.ls!(dir) == []
    end

    test "a name that cannot be a part's is refused" do
      assert {:error, sentence} = Parts.install("../escape", "ISO-10303-21;")
      assert sentence =~ "letters, digits"
    end
  end

  describe "describing a part" do
    test "answers the size, the face count and the features the recognition found" do
      assert {:ok, described} = Parts.describe("solidcraft-plate")

      assert described.extent == [80.0, 50.0, 22.0]
      assert described.faces == 15

      assert described.features == [
               %{id: "fillets/0", family: "fillets", verified?: true},
               %{id: "fillets/1", family: "fillets", verified?: true},
               %{id: "fillets/2", family: "fillets", verified?: true},
               %{id: "fillets/3", family: "fillets", verified?: true},
               %{id: "bosses/0", family: "bosses", verified?: true},
               %{id: "holes/0", family: "holes", verified?: true},
               %{id: "holes/1", family: "holes", verified?: true},
               %{id: "holes/2", family: "holes", verified?: true},
               %{id: "plates/0", family: "plates", verified?: true},
               %{id: "risers/0", family: "risers", verified?: true}
             ]
    end

    test "is refused for a name no part answers" do
      assert {:error, sentence} = Parts.describe("nothing_by_that_name")
      assert sentence =~ "no part"
    end
  end
end
