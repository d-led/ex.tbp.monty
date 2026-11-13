defmodule ExamplePlugin.RegistrationTest do
  @moduledoc """
  The application, started the way a release starts it, is what a cluster sees.

  These cases run against the running application rather than a supervisor the
  test builds, because the thing being specified is that booting this node offers
  the plugins — a registration made by a test proves the registry works, which is
  `ex_monty_plugin`'s case, not this one.
  """

  use ExUnit.Case, async: true

  test "every plugin is offered on this node, with a description a caller can use" do
    for plugin <- ExamplePlugin.plugins() do
      description = plugin.describe()

      assert {:ok, provider} =
               MontyPlugin.Registry.lookup(description["kind"], description["name"], node())

      assert provider.node == node()
      assert {:ok, ^description} = provider.describe
    end
  end

  test "the cluster can be asked what it offers, one kind at a time" do
    names = Enum.map(MontyPlugin.Registry.providers(:motor_policy), & &1.name)

    assert ExamplePlugin.Policy.name() in names
  end

  test "the run the experiment asks for names plugins this node offers" do
    run = ExamplePlugin.Experiment.run()

    for {kind, name} <- modules_named_in(run) do
      assert {:ok, _provider} = MontyPlugin.Registry.lookup(kind, name),
             "#{inspect(name)} is named by the run and offered by nobody"
    end
  end

  # The definition names its modules the way a run asks for them, so reading it
  # is the only thing that knows which key is which kind.
  defp modules_named_in(%{"learning_modules" => modules, "motor_system" => motor_system}) do
    Enum.map(modules, &{:learning_module, &1}) ++ [{:motor_policy, motor_system}]
  end
end
