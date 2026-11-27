defmodule Monty.ModuleMap.TestMapTest do
  @moduledoc """
  What the test map reads from a port test file, and how it accounts for a case
  it cannot translate.

  The case names are built rather than written: this file is itself in the tree
  the map reads, and a literal `# test_...` line here would be read as a
  translation of a case Monty does not define.
  """

  use ExUnit.Case, async: true

  alias Monty.ModuleMap.TestMap

  defp translated, do: "test_" <> "a_translated_case"
  defp python_only, do: "test_" <> "a_python_only_case"
  defp invented, do: "test_" <> "the_port_invented"

  # The case table Monty's `thing_test.py` would give: one case a translation can
  # have, one a Python-only mechanism owns.
  defp monty, do: %{"thing_test.py" => [translated(), python_only()]}

  defp port_tree(body) do
    root = Path.join(System.tmp_dir!(), "test-map-#{System.unique_integer([:positive])}")
    path = Path.join(root, "test/thing_test.exs")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule ThingTest do\n" <> body <> "\n  use ExUnit.Case\nend\n")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp port_file, do: "test/thing_test.exs"

  defp exclusion_line, do: "  # excluded #{python_only()}: a Python mechanism owns it\n"

  defp tree_with_a_translation_and_an_exclusion do
    port_tree("  # #{translated()}\n" <> exclusion_line())
  end

  describe "a case the port cannot have" do
    test "its line reads as the name and the reason, and not as a translation" do
      root = tree_with_a_translation_and_an_exclusion()

      assert TestMap.exclusions(root) == %{
               port_file() => [%{case: python_only(), reason: "a Python mechanism owns it"}]
             }

      assert TestMap.attributions(root) == %{port_file() => [translated()]}
    end

    test "is accounted for once: named, excluded, or still to translate" do
      root = tree_with_a_translation_and_an_exclusion()

      coverage =
        TestMap.coverage(monty(), TestMap.attributions(root), TestMap.excluded_cases(root))

      assert coverage == %{named: 1, excluded: 1, total: 2, missing: %{}}
    end

    test "a reason attached to a case Monty does not define is a defect" do
      root = port_tree("  # excluded #{invented()}: a Python mechanism owns it\n")

      assert TestMap.exclusion_problems(
               monty(),
               TestMap.attributions(root),
               TestMap.exclusions(root)
             ) == [%{port: port_file(), case: invented(), problem: :unknown}]
    end

    test "a case that is both excluded and named is a contradiction" do
      root = port_tree("  # #{python_only()}\n" <> exclusion_line())

      assert TestMap.exclusion_problems(
               monty(),
               TestMap.attributions(root),
               TestMap.exclusions(root)
             ) == [%{port: port_file(), case: python_only(), problem: :also_named}]
    end
  end
end
