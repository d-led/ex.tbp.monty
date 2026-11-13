defmodule ExamplePlugin.DefinitionTest do
  @moduledoc """
  The experiment plugin as the studio asks it: one question, one answer, and the
  answer is data.

  The run a plugin defines is read over the cluster, so what travels is the map
  `run/0` returns — a config's name and the modules the run wants. What is
  specified here is that the process answers that question, and that a plugin
  which defines no run says so instead of answering something empty.
  """

  use ExUnit.Case, async: true

  test "the experiment answers the run it defines" do
    {:ok, provider} =
      MontyPlugin.Registry.lookup(:experiment, ExamplePlugin.Experiment.name(), node())

    assert {:ok, definition} = GenServer.call(provider.pid, :run)

    assert definition["base"] == "base_10simobj_surf_agent"
    assert definition["motor_system"] == ExamplePlugin.Policy.name()
  end

  # The learning module cannot be stepped from another node (`docs/plugins.md`),
  # so the definition that is startable names none of them — and a definition that
  # did would be refused by the caller, which is a case of its own on the studio
  # side.
  test "the definition asks for no plugin learning module, because none can be routed" do
    {:ok, definition} = GenServer.call(provider(:experiment).pid, :run)

    assert definition["learning_modules"] == []
  end

  test "a plugin that defines no run says so rather than answering nothing" do
    assert {:error, why} = GenServer.call(provider(:learning_module).pid, :run)

    assert why =~ "defines no run"
  end

  defp provider(kind) do
    name =
      case kind do
        :experiment -> ExamplePlugin.Experiment.name()
        :learning_module -> ExamplePlugin.LearningModule.name()
      end

    {:ok, provider} = MontyPlugin.Registry.lookup(kind, name, node())
    provider
  end
end
