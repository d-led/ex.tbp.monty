defmodule FlyversePlugin.NativeTest do
  use ExUnit.Case, async: true

  alias FlyversePlugin.{Demonstrator, Native, Pack}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "flyverse_native_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, _written} = Pack.write(directory, Demonstrator.spec())
    {:ok, connectome} = Native.open(directory)

    # The plan is the pack's: `Demonstrator.spec/0` is the map the pack was
    # written from, so a test never restates the wiring it is testing.
    {:ok, directory: directory, connectome: connectome, plan: Demonstrator.spec().plan}
  end

  test "the engine is loaded" do
    assert Native.loaded?()
  end

  test "flyverse's loader reads a pack this writer wrote", %{connectome: connectome} do
    assert Native.census(connectome) == {4, 2}
  end

  test "a pack with an array missing is refused, and the sentence names it", %{
    directory: directory
  } do
    File.rm!(Path.join(directory, "destinations.npy"))

    assert {:error, {code, sentence}} = Native.open(directory)
    assert code == "pack"
    assert sentence =~ "destinations.npy"
  end

  test "a driven group fires its own readout and not the other one", %{
    connectome: connectome,
    plan: plan
  } do
    {:ok, simulation} = simulation(connectome, plan)

    {left, right} = counts(simulation, connectome, plan, 160.0, 0.0, 10)

    assert left > 0
    assert right == 0
  end

  test "a faster drive is more spikes", %{connectome: connectome, plan: plan} do
    {:ok, slow_simulation} = simulation(connectome, plan)
    {slow, _right} = counts(slow_simulation, connectome, plan, 80.0, 0.0, 10)

    {:ok, fast_simulation} = simulation(connectome, plan)
    {fast, _right} = counts(fast_simulation, connectome, plan, 300.0, 0.0, 10)

    assert fast > slow
  end

  test "a window is the same window every time, and a reset starts it again", %{
    connectome: connectome,
    plan: plan
  } do
    {:ok, simulation} = simulation(connectome, plan)

    {:ok, first} = Native.window(simulation, connectome, plan["ticks"], stimuli(160.0, 0.0))
    {:ok, second} = Native.window(simulation, connectome, plan["ticks"], stimuli(160.0, 0.0))

    assert elem(first, 1) > 0
    assert elem(second, 2) == elem(first, 2) + elem(second, 1)

    assert :ok = Native.reset(simulation)

    assert {:ok, again} =
             Native.window(simulation, connectome, plan["ticks"], stimuli(160.0, 0.0))

    assert again == first
  end

  test "a stimulus for every drive group, or a refusal that says so", %{
    connectome: connectome,
    plan: plan
  } do
    {:ok, simulation} = simulation(connectome, plan)

    assert {:error, {code, sentence}} =
             Native.window(simulation, connectome, 10, [{:rate, 160.0}])

    assert code == "drives"
    assert sentence =~ "2 drive group(s) but 1 stimulus(es)"
  end

  # The second way to drive a group is the one the dataset needs: `vnc_sensory`
  # is a *recording* — which sensory neuron fired on which tick — not a rate, and
  # a policy that only had a rate to offer could not present it at all. A replay
  # is copied in, per neuron, on the simulation's own clock.
  test "a recording drives the group whose neurons fired, and only on its ticks", %{
    connectome: connectome,
    plan: plan
  } do
    {:ok, simulation} = simulation(connectome, plan)

    train = Enum.to_list(0..190//10)

    {:ok, {[left, right], spikes, _total}} =
      Native.window(simulation, connectome, plan["ticks"], [
        {:ticks, [train]},
        {:ticks, [[]]}
      ])

    assert left > 0, "the left readout fired on the left group's recording"
    assert right == 0, "and the right group was given no spikes at all"
    assert spikes > 0
  end

  # The ticks are on the simulation's clock, which `reset/1` sets to zero — so a
  # tick the window has not reached yet is not lost, it fires when it is reached.
  test "a recording fires on its own tick, not on the window it arrives in", %{
    connectome: connectome,
    plan: plan
  } do
    {:ok, simulation} = simulation(connectome, plan)
    recording = [{:ticks, [[250]]}, {:ticks, [[]]}]

    {:ok, {[left_before, right_before], spikes_before, _}} =
      Native.window(simulation, connectome, plan["ticks"], recording)

    assert {left_before, right_before} == {0, 0}
    assert spikes_before == 0, "tick 250 is beyond this window, so nothing fired"

    {:ok, {[left, right], spikes, _}} =
      Native.window(simulation, connectome, plan["ticks"], recording)

    assert left > 0, "the next window covers tick 250, and the left readout fired"
    assert right == 0
    assert spikes > 0
  end

  # And a recording whose ticks are behind the window is not replayed. The
  # comparison is against a simulation that was sent no spikes at all rather than
  # against zero: a network that was just driven is still charged, and a neuron
  # that is above threshold fires whether or not anything new arrived.
  test "a tick already passed is not replayed", %{connectome: connectome, plan: plan} do
    {:ok, with_replay} = simulation(connectome, plan)
    {:ok, without} = simulation(connectome, plan)
    recording = [{:ticks, [[0, 20, 40]]}, {:ticks, [[]]}]
    silence = [{:rate, 0.0}, {:rate, 0.0}]

    {:ok, {_counts, played, _total}} =
      Native.window(with_replay, connectome, plan["ticks"], recording)

    assert played > 0, "the recording was played in the window that covers tick 0"

    {:ok, _first} = Native.window(without, connectome, plan["ticks"], silence)

    {:ok, {replayed_counts, replayed, _total}} =
      Native.window(with_replay, connectome, plan["ticks"], recording)

    {:ok, {silent_counts, silent, _total}} =
      Native.window(without, connectome, plan["ticks"], silence)

    # The window the recording has already been played in is the window a silent
    # simulation has: a recording is a timeline, not a queue to deliver again.
    assert {replayed_counts, replayed} == {silent_counts, silent}
  end

  # A recording is per neuron, so the lists and the group's targets are the same
  # length or the caller has said something the engine cannot guess at.
  test "one list of ticks per neuron, or a refusal that names the mismatch" do
    directory =
      Path.join(System.tmp_dir!(), "flyverse_two_targets_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, _written} =
      Pack.write(directory, %{
        neuron_ids: [1, 2, 3],
        edges: [{0, 2, 200}, {1, 2, 200}],
        plan: %{"drives" => [[0, 1]], "readouts" => [[2]], "ticks" => 200, "seed" => 7}
      })

    {:ok, connectome} = Native.open(directory)
    {:ok, simulation} = Native.new(connectome, [[0, 1]], [0.0], [[2]], 7)

    assert {:error, {code, sentence}} =
             Native.window(simulation, connectome, 20, [{:ticks, [[0, 1, 2]]}])

    assert code == "drives"
    assert sentence =~ "names 2 target(s) and 1 spike list(s)"
  end

  defp stimuli(left_hz), do: [{:rate, left_hz}, {:rate, 0.0}]
  defp stimuli(left_hz, right_hz), do: [{:rate, left_hz}, {:rate, right_hz}]

  defp simulation(connectome, plan) do
    rates = Enum.map(plan["drives"], fn _group -> 0.0 end)
    Native.new(connectome, plan["drives"], rates, plan["readouts"], plan["seed"])
  end

  defp counts(simulation, connectome, plan, left_hz, right_hz, windows) do
    1..windows
    |> Enum.reduce({0, 0}, fn _window, {left, right} ->
      {:ok, {[left_now, right_now], _spikes, _total}} =
        Native.window(simulation, connectome, plan["ticks"], stimuli(left_hz, right_hz))

      {left + left_now, right + right_now}
    end)
  end
end
