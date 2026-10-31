defmodule ExTbpMonty.Mcp.Tools.CodeInDocTest do
  # The page comes from the configured documentation site, so these read one
  # stub at a time.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Test.FakeDocsHttp
  alias ExTbpMonty.Mcp.Tools.Port

  @site "https://docs.thousandbrains.org"
  @page @site <> "/docs/evidence-based-learning-module.md"

  setup do
    FakeDocsHttp.serve(%{
      @page => """
      # Evidence Based Learning Module

      The module lives in
      `src/tbp/monty/frameworks/models/evidence_matching/learning_module.py`, and
      a sensor names `tbp.monty.frameworks.models.sensor_modules.CameraSM`.
      """
    })
  end

  describe "monty_code_in_doc" do
    test "follows a page's own source references to the modules they name" do
      assert {:ok,
              %{
                text: text,
                structured: %{slug: "evidence-based-learning-module", modules: modules}
              }} =
               Port.code_in_doc(%{"slug" => "evidence-based-learning-module"}, %{})

      assert Enum.any?(modules, &(&1.python =~ "learning_module.py"))
      assert Enum.any?(modules, &(&1.elixir == "Monty.Frameworks.Models.SensorModules.CameraSM"))

      assert text =~ "Evidence Based Learning Module"
      assert text =~ "module(s) referred to"
    end

    test "says so when a page refers to nothing this port can name" do
      FakeDocsHttp.serve(%{@page => "# Evidence Based Learning Module\n\nNo code here.\n"})

      assert {:ok, %{text: text, structured: %{modules: []}}} =
               Port.code_in_doc(%{"slug" => "evidence-based-learning-module"}, %{})

      assert text =~ "does not refer to any module"
    end

    test "says a page is missing rather than failing" do
      assert {:error, message} = Port.code_in_doc(%{"slug" => "no-such-page"}, %{})
      assert message =~ "There is no page `no-such-page`"
    end

    test "says the site could not be reached rather than failing" do
      FakeDocsHttp.serve(%{@page => {:error, :timeout}})

      assert {:error, message} =
               Port.code_in_doc(%{"slug" => "evidence-based-learning-module"}, %{})

      assert message =~ "could not be reached"
    end

    test "asks for the slug it needs" do
      assert Port.code_in_doc(%{}, %{}) == {:error, "`slug` is required."}
    end
  end
end
