defmodule Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTrackerNativeParityTest do
  @moduledoc """
  The kernel answers what the reference answers, bit for bit.

  `EvidenceSlopeTracker.calculate_slopes/1` takes a kernel when the native
  kernels load and walks the same bytes in Elixir otherwise, and the two must
  agree exactly: the kernel performs the reference's arithmetic in the
  reference's order, so a difference in the last bit is a difference in what was
  computed rather than rounding.

  `async: false` because the switch is application configuration and a
  concurrently running test would read it while this one holds it.
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.MatcherNif
  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker

  setup do
    on_exit(fn -> Application.delete_env(:ex_tbp_monty, :native_kernels?) end)
    :ok
  end

  test "the kernel is loaded on this machine" do
    assert MatcherNif.loaded?()
  end

  test "every slope is the same number either way" do
    # A window that is partly unfilled (the first two updates), a hypothesis
    # whose evidence falls, one that is flat, and a step fed by three channels —
    # the cases the parity replay of Monty's answers also covers, here asked of
    # both implementations of the same bytes.
    tracker =
      EvidenceSlopeTracker.new(window_size: 4, min_age: 2)
      |> EvidenceSlopeTracker.add_hyp(3)
      |> update!([0.0, 5.0, 2.0], num_channels: 1)
      |> update!([1.0, 4.0, 2.0], num_channels: 2)
      |> update!([2.0, 3.0, 2.0], num_channels: 3)
      |> update!([3.0, 2.0, 4.0], num_channels: 1)

    native = EvidenceSlopeTracker.calculate_slopes(tracker)

    reference =
      with_reference(fn -> EvidenceSlopeTracker.calculate_slopes(tracker) end)

    assert native == reference
    assert Enum.all?(native, &is_float/1)
  end

  test "a window with no filled pair has no slope either way" do
    tracker =
      EvidenceSlopeTracker.new(window_size: 3, min_age: 2)
      |> EvidenceSlopeTracker.add_hyp(2)
      |> update!([1.0, 2.0])

    assert EvidenceSlopeTracker.calculate_slopes(tracker) == [nil, nil]

    assert with_reference(fn -> EvidenceSlopeTracker.calculate_slopes(tracker) end) == [nil, nil]
  end

  defp update!(tracker, values, opts \\ []) do
    assert {:ok, tracker} = EvidenceSlopeTracker.update(tracker, values, opts)
    tracker
  end

  defp with_reference(fun) do
    Application.put_env(:ex_tbp_monty, :native_kernels?, false)
    answer = fun.()
    Application.delete_env(:ex_tbp_monty, :native_kernels?)
    answer
  end
end
