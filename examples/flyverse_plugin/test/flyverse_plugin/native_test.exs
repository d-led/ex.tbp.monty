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

    {:ok, first} = Native.window(simulation, connectome, plan["ticks"], [160.0, 0.0])
    {:ok, second} = Native.window(simulation, connectome, plan["ticks"], [160.0, 0.0])

    assert elem(first, 1) > 0
    assert elem(second, 2) == elem(first, 2) + elem(second, 1)

    assert :ok = Native.reset(simulation)
    assert {:ok, again} = Native.window(simulation, connectome, plan["ticks"], [160.0, 0.0])
    assert again == first
  end

  test "a rate for every drive group, or a refusal that says so", %{
    connectome: connectome,
    plan: plan
  } do
    {:ok, simulation} = simulation(connectome, plan)

    assert {:error, {code, sentence}} = Native.window(simulation, connectome, 10, [160.0])
    assert code == "drives"
    assert sentence =~ "2 drive group(s) but 1 rate(s)"
  end

  defp simulation(connectome, plan) do
    rates = Enum.map(plan["drives"], fn _group -> 0.0 end)
    Native.new(connectome, plan["drives"], rates, plan["readouts"], plan["seed"])
  end

  defp counts(simulation, connectome, plan, left_hz, right_hz, windows) do
    1..windows
    |> Enum.reduce({0, 0}, fn _window, {left, right} ->
      {:ok, {[left_now, right_now], _spikes, _total}} =
        Native.window(simulation, connectome, plan["ticks"], [left_hz, right_hz])

      {left + left_now, right + right_now}
    end)
  end
end
