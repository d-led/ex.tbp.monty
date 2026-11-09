defmodule Monty.Studio.RunHistory.JsonTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.RunHistory.Json

  # The type Ecto uses for a run's `log` and `timeline`: a JSON column that is a
  # map or a list, and nothing else. Anything else is an error rather than a
  # value the page would have to defend against.
  describe "a map or a list" do
    test "is what the column holds" do
      assert Json.cast(%{"a" => 1}) == {:ok, %{"a" => 1}}
      assert Json.load([%{"step" => 0}]) == {:ok, [%{"step" => 0}]}
      assert Json.dump([]) == {:ok, []}
    end

    test "is what a run that has written nothing holds" do
      assert Json.load(nil) == {:ok, nil}
      assert Json.dump(nil) == {:ok, nil}
    end
  end

  describe "anything else" do
    test "is refused rather than stored" do
      assert Json.cast("mug") == :error
      assert Json.load(42) == :error
      assert Json.dump(:mug) == :error
    end
  end

  test "names the Ecto type it is" do
    assert Json.type() == :map
  end
end
