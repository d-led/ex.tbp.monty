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

    test "the payload is the steps, decoded, for a hook that knows nothing of Elixir" do
      assert Tour.steps() == Jason.decode!(Tour.payload(), keys: :atoms)
    end

    test "the browser is told where to remember having seen it" do
      assert Tour.seen_key() =~ "tour"
    end
  end
end
