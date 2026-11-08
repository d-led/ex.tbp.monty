defmodule Monty.Attention.TelemetryTest do
  @moduledoc """
  No test file for this in Monty: its telemetry is exercised through
  `tests/unit/attention/attention_system_test.py`, which reaches it through the
  attention system.

  These are **intent tests**, not translations — they state what a recording
  telemetry is for. Parity evidence for these modules will be the attention
  system's cases, once that is ported.
  """

  use ExUnit.Case, async: true

  alias Monty.Attention.Telemetry

  alias Monty.Attention.Telemetry.{
    DefaultAttentionSystemTelemetry,
    NoopAttentionSystemTelemetry
  }

  alias Monty.Attention.VoxelGrid

  defp grid(weight), do: VoxelGrid.new(1.0, [{0, 0, 0}], [weight])

  describe "DefaultAttentionSystemTelemetry" do
    test "keeps proposed grids apart from the grids attention kept, in arrival order" do
      proposed = grid(0.1)
      kept = grid(0.2)

      telemetry =
        Telemetry.default()
        |> DefaultAttentionSystemTelemetry.proposed_grid(proposed)
        |> DefaultAttentionSystemTelemetry.grid(kept)

      assert DefaultAttentionSystemTelemetry.state_dict(telemetry) == %{
               grids: [kept],
               proposed_grids: [proposed]
             }
    end

    test "reset forgets everything recorded so far" do
      telemetry =
        Telemetry.default()
        |> DefaultAttentionSystemTelemetry.grid(grid(0.2))
        |> DefaultAttentionSystemTelemetry.reset()

      assert DefaultAttentionSystemTelemetry.state_dict(telemetry) == %{
               grids: [],
               proposed_grids: []
             }
    end
  end

  describe "NoopAttentionSystemTelemetry" do
    test "records nothing and still answers a state dict" do
      telemetry =
        %NoopAttentionSystemTelemetry{}
        |> NoopAttentionSystemTelemetry.grid(grid(0.2))
        |> NoopAttentionSystemTelemetry.proposed_grid(grid(0.1))

      assert NoopAttentionSystemTelemetry.state_dict(telemetry) == %{
               grids: [],
               proposed_grids: []
             }
    end
  end
end
