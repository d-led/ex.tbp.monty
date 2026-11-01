defmodule ExTbpMontyWeb.TourTest do
  use ExUnit.Case, async: true

  alias ExTbpMontyWeb.Tour

  describe "the walkthrough, as the browser receives it" do
    test "every step can be shown: a target, a title and something to read" do
      for step <- Tour.steps() do
        assert is_binary(step.element) and step.element != ""
        assert is_binary(step.popover.title) and step.popover.title != ""
        assert is_binary(step.popover.description) and step.popover.description != ""
      end
    end

    test "no two steps point at the same place" do
      selectors = Enum.map(Tour.steps(), & &1.element)

      assert selectors == Enum.uniq(selectors)
    end

    test "a step says which page it describes, and every scope has one" do
      for step <- Tour.steps() do
        assert step.scope in Tour.scopes(),
               "#{step.element} is scoped #{inspect(step.scope)}, which no page asks for"
      end

      for scope <- Tour.scopes() do
        assert Tour.steps(scope) != [], "nothing in the tour describes #{scope}"
      end
    end

    test "the page-specific steps stay on their page" do
      assert Enum.all?(Tour.steps(:welcome), &(&1.scope == :welcome))
      refute Tour.steps(:welcome) == Tour.steps(:index)
    end

    test "the payload is the steps, decoded, for a hook that knows nothing of Elixir" do
      assert Jason.decode!(Tour.payload(), keys: :atoms) ==
               Enum.map(Tour.steps(), &Map.take(&1, [:element, :popover]))
    end

    test "the browser is told where to remember having seen it" do
      assert Tour.seen_key() =~ "tour"
    end
  end
end
