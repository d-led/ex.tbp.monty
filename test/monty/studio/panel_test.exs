defmodule Monty.Studio.PanelTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.{Panel, Setup}

  # The ten-object config Monty ships, read the way a page reads it: what a run
  # of it is, in the words the configuration panel uses.
  defp setup do
    {:ok, setup} = Setup.from_experiment("base_config_10distinctobj_dist_agent")
    setup
  end

  defp facts(seed \\ nil), do: setup() |> Panel.facts(seed) |> Map.new()

  test "says which phase the config runs, not what its epoch counts say" do
    # This config names three train epochs and switches training off: a panel
    # that read `n_train_epochs` would promise a phase the run never enters.
    assert facts()["training · evaluation"] == "train no · eval yes"
    assert facts()["episodes, as the config runs them"] == "140 eval"
  end

  test "names the seed the run is under, which is the config's until one is chosen" do
    assert facts()["seed"] == "42"
    assert facts(7)["seed"] == "7"
  end

  test "says what the termination allows, and that it names nothing when it does not" do
    assert facts()["steps, as the config limits them"] =~ "max eval 500"
    assert facts()["steps, as the config limits them"] =~ "total 6000"

    nameless = %{setup() | termination: %{}, monty_args: %{}}

    assert Panel.facts(nameless) |> Map.new() |> Map.get("steps, as the config limits them") ==
             "not named by the config"
  end

  test "names the modules and the memory the run starts from" do
    assert facts()["sensors"] == "patch, view_finder"
    assert facts()["learning modules"] == "learning_module_0"
    assert facts()["model"] != ""
    assert facts()["ported here"] =~ "/"
  end

  test "says which data the run reads" do
    # The objects are the config's — this one names the YCB set — so the line is
    # the directory a reader can look in, not a category invented here.
    assert facts()["input"] =~ "objects/ycb"
  end

  test "has no input line for a config that names no data" do
    nameless = put_in(setup().environment.data_path, nil)

    refute Map.has_key?(Panel.facts(nameless) |> Map.new(), "input")
  end
end
