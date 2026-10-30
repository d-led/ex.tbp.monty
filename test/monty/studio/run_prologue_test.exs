defmodule Monty.Studio.RunPrologueTest do
  @moduledoc """
  An episode starts the way Monty starts one: the world is reset, and only then
  is anything positioned or stepped.

  The world under test is the probe behind the port rather than Habitat, because
  the claim is about the run asking its world for an episode at all — a world in
  another process starts nothing until it is told to. Without the reset a run
  stepped a world that had never been told an episode had begun, which is also
  why a world that positions an episode itself had never done so.
  """

  use ExUnit.Case, async: false

  alias Monty.Studio.Run
  alias Monty.Test.Tmp

  @experiment "base_config_10distinctobj_dist_agent"
  @peer Path.expand("../../support/probe_world.py", __DIR__)

  setup do
    log = Path.join(Tmp.dir("peer-requests"), "requests.txt")

    Tmp.app_env(:world_simulator, :habitat)
    Tmp.app_env(:monty_peer, python: System.find_executable("python3"), peer: @peer)
    Tmp.system_env("PROBE_WORLD_LOG", log)

    {:ok, opened} = Monty.Studio.open(@experiment)

    {:ok, setup: opened.setup, log: log}
  end

  test "the world is asked for an episode before the run steps it", %{setup: setup, log: log} do
    {:ok, run} = Run.start(setup, steps: 1)

    try do
      # A world that positions itself has done so inside that reset, so the run
      # does not walk the procedures over an agent Monty already placed.
      assert run.positioning == %{steps: nil, success: true, procedures: [:world]}
      assert requested?(log, "reset"), "the world was never asked for an episode"
    after
      Run.stop(run)
    end
  end

  # What the probe behind the port was sent. A world that is never asked anything
  # writes nothing, which is itself the answer.
  defp requested?(log, command) do
    case File.read(log) do
      {:ok, requests} -> requests =~ command
      {:error, :enoent} -> false
    end
  end
end
