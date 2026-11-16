defmodule ExTbpMonty.AnimalExperimentsTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.AnimalExperiments
  alias Monty.Config.Source

  describe "the tree this application's own experiments live in" do
    # `mix monty.inputs` mirrors Monty's `conf/` and `snapshots/` into
    # `priv/monty` and deletes every other YAML under those two prefixes. A
    # config written inside that copy survives until the next refresh and then
    # vanishes without a message, so the tree is held to being somewhere else.
    test "is outside the copy a refresh mirrors" do
      # The separator matters: `priv/monty_experiments` starts with the letters
      # of `priv/monty` and is still a different tree.
      refute String.starts_with?(AnimalExperiments.conf_dir(), Source.inputs_root() <> "/")
    end

    test "is the tree the plan and the README point a person at" do
      assert AnimalExperiments.conf_dir() |> Path.split() |> Enum.take(-2) == [
               "monty_experiments",
               "conf"
             ]
    end
  end
end
