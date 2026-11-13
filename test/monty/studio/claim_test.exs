defmodule Monty.Studio.ClaimTest do
  @moduledoc """
  A part of a run belongs to one node until its lease runs out — the small piece
  of arithmetic the whole recovery story stands on: a claim that lapsed is
  claimable, and a token that is not the row's token writes nothing.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Claim

  @now ~U[2026-11-13 09:00:00.000000Z]

  describe "a claim" do
    test "is the node's for a whole lease, and nobody's after it" do
      claim = Claim.new(run(), 1, "node1_127.0.0.1", @now)

      refute Claim.lapsed?(claim, at(@now, seconds: 599))
      assert Claim.lapsed?(claim, at(@now, seconds: 600))
      assert Claim.lapsed?(claim, at(@now, seconds: 601))
    end

    test "is nobody's before it is made" do
      assert Claim.lapsed?(nil, @now)
    end

    test "is nobody's once it has been given back" do
      claim = %{Claim.new(run(), 0, "node1_127.0.0.1", @now) | until: nil}

      assert Claim.lapsed?(claim, @now)
    end

    test "keeps its token when it is renewed, and lives longer" do
      claim = Claim.new(run(), 0, "node1_127.0.0.1", @now)
      renewed = Claim.renew(claim, at(@now, seconds: 500))

      assert renewed.token == claim.token
      assert renewed.until == at(@now, seconds: 1100)
      refute Claim.lapsed?(renewed, at(@now, seconds: 1099))
    end

    test "gives every claim of a part its own token" do
      one = Claim.new(run(), 0, "node1_127.0.0.1", @now)
      two = Claim.new(run(), 0, "node2_127.0.0.1", @now)

      assert one.token != two.token
    end
  end

  describe "whether a token still owns the row" do
    test "yes while the row carries it and its lease has not run out" do
      row = %{claim: "token-a", claimed_until: at(@now, seconds: 600)}

      assert Claim.holds?(row, "token-a", @now)
    end

    test "no for the token of a claim that was given away" do
      row = %{claim: "token-a", claimed_until: at(@now, seconds: 600)}

      refute Claim.holds?(row, "token-b", @now)
    end

    test "no once the lease has run out, whatever the token says" do
      row = %{claim: "token-a", claimed_until: at(@now, seconds: 600)}

      refute Claim.holds?(row, "token-a", at(@now, seconds: 600))
    end

    test "no for a row nobody has claimed" do
      refute Claim.holds?(%{claim: nil, claimed_until: nil}, "token-a", @now)
      refute Claim.holds?(%{}, "token-a", @now)
    end
  end

  defp run, do: Ecto.UUID.generate()

  defp at(now, seconds: seconds), do: DateTime.add(now, seconds, :second)
end
