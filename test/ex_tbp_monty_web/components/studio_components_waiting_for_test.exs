defmodule ExTbpMontyWeb.StudioComponents.WaitingForTest do
  @moduledoc """
  The one sentence a queued run needs when it is waiting for a node rather than
  for a worker: who it waits for, and the tag this node cannot offer.

  The decision behind it is `ExTbpMonty.Cluster.Placement.awaiting/2` and is
  tested there; this is only what a page draws.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ExTbpMontyWeb.StudioComponents

  test "names the node it waits for and the tag this one lacks" do
    html =
      render_component(&StudioComponents.waiting_for/1, %{
        waiting: %{
          nodes: [entry("mujoco_10.0.0.7"), entry("mujoco_10.0.0.8")],
          missing: ["world:mujoco"]
        }
      })

    assert html =~ "waits for mujoco_10.0.0.7, mujoco_10.0.0.8"
    assert html =~ "This node does not offer world:mujoco."
  end

  test "says enough when it cannot name a missing tag" do
    html =
      render_component(&StudioComponents.waiting_for/1, %{
        waiting: %{nodes: [entry("peer_10.0.0.9")], missing: []}
      })

    assert html =~ "waits for peer_10.0.0.9"
    assert html =~ "Another node can take this run before this one."
  end

  defp entry(name), do: %{name: name, self: false, alive: true, capabilities: ["monty"]}
end
