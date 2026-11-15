# Is our first action Monty's? The one action that needs no percept.
#
#   MIX_ENV=test mix run --no-start scripts/probe_action_parity.exs [experiment]
#
# A surface episode opens with the same act in Monty's policy: if the view finder
# sees the object within a metre, move forward until it is at
# `desired_object_distance`. The distance is arithmetic on the view finder's
# middle depth and the sensor's own offset — nothing about the model, nothing
# about a percept — so it is the one action that can be compared on its own, and
# his recording has it: `move_forward` of `0.036434554755687715`.
#
# This asks our world the same question. If the answer is his number, the body
# starts where his starts, and everything after it is the policy's own stream.

defmodule ActionParity do
  @moduledoc false

  alias Monty.Frameworks.Environments.PositioningProcedures
  alias Monty.Studio
  alias Monty.Studio.Setup

  @agent "agent_id_0"
  @view_finder "view_finder"
  @fixture "test/fixtures/monty_base_10simobj_episode.jsonl"

  def main do
    experiment = System.argv() |> List.first() || "base_10simobj_surf_agent"
    his = recorded_distance(Path.join(__DIR__, "..") |> Path.join(@fixture))

    {:ok, opened} = Studio.open(experiment, world_simulator: :mujoco)
    setup = opened.setup

    {:ok, _python} = Application.ensure_all_started(:pythonx)
    {:ok, _host} = Monty.Simulators.Mujoco.Host.start_link([])

    # The step Monty's episode opens on: the world's own first view.
    world = setup |> Setup.world(:mujoco, 0) |> then(& &1.__struct__.reset(&1))
    {observations, _state, _world} = world.__struct__.step(world, [])

    ours =
      observations
      |> PositioningProcedures.depth_at_center(@agent, @view_finder)
      |> then(&(&1 - 0.025 - 0.03))

    IO.puts("his move_forward:  #{inspect(his)}")
    IO.puts("ours:              #{inspect(ours)}")

    # A micro-metre is the tolerance, not a last bit: the two depths differ in
    # the ninth decimal because the pose that produced them was composed along a
    # slightly different float path, and a policy whose thresholds are millimetres
    # cannot tell the two apart. What would matter is any difference a threshold
    # could see.
    difference = abs(ours - his)

    cond do
      difference == 0.0 ->
        IO.puts("\nthe first action is his, to the last bit")

      difference < 1.0e-6 ->
        IO.puts("\nthe first action is his to #{:erlang.float_to_binary(difference, scientific: 3)} m")

      true ->
        IO.puts("\nthe first action differs by #{inspect(ours - his)}")
        System.halt(1)
    end
  end

  # The distance of the recording's opening `move_forward`.
  defp recorded_distance(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find_value(fn step ->
      case step["actions"] do
        [%{"action" => "move_forward", "distance" => distance} | _rest] -> distance
        _none -> nil
      end
    end)
  end
end

ActionParity.main()
