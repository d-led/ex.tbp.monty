defmodule Monty.ModuleMap.TableTest do
  use ExUnit.Case, async: true

  alias Monty.ModuleMap
  alias Monty.ModuleMap.Table

  @repo "https://example.test/repo"
  @revision "deadbee"

  defp rows, do: Table.rows(repo: @repo, revision: @revision)

  defp row!(class) do
    Enum.find(rows(), &(&1.class == class)) || flunk("the map has no class #{class}")
  end

  describe "the rows" do
    test "are the generated map, one per class" do
      summary = ModuleMap.summary(ModuleMap.load())

      assert length(rows()) == summary.classes
      assert Enum.map(rows(), & &1.class) |> Enum.member?("GraphLM")
    end

    test "link the Monty side at the commit the map records" do
      commit = ModuleMap.sources()["monty"]["commit"]
      camera = row!("CameraSM")

      assert camera.python_url ==
               "https://github.com/thousandbrainsproject/tbp.monty/blob/#{commit}/" <>
                 "src/tbp/monty/frameworks/models/sensor_modules.py"

      assert camera.file == "frameworks/models/sensor_modules.py"
    end

    test "link our side only where the module is written" do
      # Every module is a link: a written one at the file the generator recorded
      # for it — which is why `AnyLMsMatch` points at `any_lms_match.ex` and not
      # at the `any_l_ms_match.ex` a plain snake-case would give — and a class
      # that is only named at the path its own name gives it.
      assert Enum.all?(
               rows(),
               &String.starts_with?(&1.elixir_url, "#{@repo}/blob/#{@revision}/lib/")
             )

      assert row!("CameraSM").elixir_url ==
               "#{@repo}/blob/#{@revision}/lib/monty/frameworks/models/sensor_modules/camera_sm.ex"

      assert row!("AnyLMsMatch").elixir_url ==
               "#{@repo}/blob/#{@revision}/lib/monty/experiment/match_criteria/any_lms_match.ex"

      assert row!("GraphLM").elixir_url ==
               "#{@repo}/blob/#{@revision}/lib/monty/frameworks/models/graph_matching/graph_lm.ex"
    end

    test "link the test beside each file" do
      # Monty keeps `tests/unit` mirroring `src/tbp/monty`, and ours mirrors
      # `lib/`: a row is a way into the code and into what checks it.
      camera = row!("CameraSM")

      assert camera.monty_test_url ==
               "https://github.com/thousandbrainsproject/tbp.monty/blob/" <>
                 "#{ModuleMap.sources()["monty"]["commit"]}/tests/unit/frameworks/models/sensor_modules_test.py"

      assert camera.test_url ==
               "#{@repo}/blob/#{@revision}/test/monty/frameworks/models/sensor_modules/camera_sm_test.exs"

      # A class that is only named has no module here, so it has no test of ours.
      assert row!("GraphLM").test_url == nil

      # `tbp.teleop` ships no tests, so its rows offer none rather than a link
      # to a tree that is not there.
      teleop = Enum.find(rows(), &(&1.package == "teleop"))
      assert teleop.monty_test_url == nil
    end

    test "carry what stands in for a class the runtime replaces" do
      shell = row!("MontyForGraphMatching")

      assert shell.status == :planned

      assert Enum.map(shell.stand_ins, &Table.describe/1) ==
               ["Monty.Runtime.Model", "Monty.Runtime.Step"]

      assert Enum.all?(shell.stand_ins, & &1.url)
    end

    test "name the carried world for a MuJoCo class, and nothing for a class that is simply not written" do
      world = row!("MuJoCoSimulator")

      assert [stand_in] = world.stand_ins
      assert Table.describe(stand_in) == "priv/monty_py/world.py"
      assert stand_in.url == "#{@repo}/blob/#{@revision}/priv/monty_py/world.py"

      # `GraphLM` has no stand-in: a config naming a learning module this
      # application has not written is refused, and the table says so by saying
      # nothing.
      assert row!("GraphLM").stand_ins == []
    end
  end

  describe "filtering" do
    test "matches any word of the row, all of them at once" do
      # One word from the class and one from the status, and no column named:
      # what a reader types when they are looking for work that is left. Every
      # word has to match, so a class and a status it does not have finds
      # nothing.
      found = Table.filter(rows(), "graphlm planned", :all)

      assert Enum.any?(found, &(&1.class == "GraphLM"))
      assert Enum.all?(found, &(&1.status == :planned))
      assert Table.filter(rows(), "camera graphlm", :all) == []
    end

    test "finds a module by the way it is written and the way it is said" do
      by_written = Table.filter(rows(), "Monty.Runtime.Model", :all)
      by_spoken = Table.filter(rows(), "runtime model", :all)

      # Substring matching is broader spoken than written — `runtime` and
      # `model` are also two ordinary words in other rows — so the property is
      # that saying it a different way never loses a row.
      written = Enum.map(by_written, & &1.class)
      assert written -- Enum.map(by_spoken, & &1.class) == []
      assert written == ["Monty", "MontyForGraphMatching"]
    end

    test "is case-insensitive and takes several words out of order" do
      assert Table.filter(rows(), "CAMERA implemented", :all) |> Enum.map(& &1.class) == [
               "CameraSM"
             ]
    end

    test "narrows by status, and everything is a status" do
      planned = Table.filter(rows(), "", :planned)

      assert planned != []
      assert Enum.all?(planned, &(&1.status == :planned))
      assert length(Table.filter(rows(), "", :all)) == length(rows())
    end

    test "a status the page does not offer is no filter at all" do
      assert Table.status("planned") == :planned
      assert Table.status("nonsense") == :all
      assert Table.status(nil) == :all
    end

    test "a row that matches nothing is left out rather than shown greyed" do
      assert Table.filter(rows(), "no class is called this", :all) == []
    end
  end
end
