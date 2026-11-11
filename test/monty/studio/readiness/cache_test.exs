defmodule Monty.Studio.Readiness.CacheTest do
  @moduledoc """
  One composition per cold node, however many pages ask for it.

  The answer is what it is — the tests that read it belong to `Readiness` — so
  these tests are about the *asking*: two pages opening together compose once, and
  a warm node composes nothing at all.
  """

  # The answer lives in `:persistent_term`, which belongs to the node and not to a
  # test, so this file runs beside nothing.
  use ExUnit.Case, async: false

  alias Monty.Studio.Readiness
  alias Monty.Studio.Readiness.Cache

  setup do
    Readiness.forget()
    :ok
  end

  test "pages opening at once are answered by one composition" do
    before = Cache.compositions()

    surveys =
      1..3
      |> Enum.map(fn _ -> Task.async(fn -> Cache.survey() end) end)
      |> Enum.map(&Task.await(&1, :timer.minutes(1)))

    assert Cache.compositions() - before == 1
    assert surveys |> Enum.uniq() |> length() == 1
  end

  test "a warm node composes nothing" do
    Cache.survey()
    before = Cache.compositions()

    Cache.survey()

    assert Cache.compositions() == before
  end
end
