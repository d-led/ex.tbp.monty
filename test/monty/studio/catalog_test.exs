defmodule Monty.Studio.CatalogTest do
  @moduledoc """
  Which of the files under Monty's `conf/experiment` are experiments.

  No test in Monty: the question only arises for a port that offers a catalogue.
  These are intent tests — they state what is counted, because a file that names
  no experiment class used to be counted, offered and then refused for an epoch
  count it does not have.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Catalog

  defp conf_dir(files) do
    dir = Path.join(System.tmp_dir!(), "catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "experiment"))

    for {name, body} <- files do
      path = Path.join([dir, "experiment", name <> ".yaml"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @experiment """
  # @package _global_
  defaults:
    - /monty: graph_exp20_e3_t3
  experiment:
    _target_: tbp.monty.frameworks.experiments.object_recognition_experiments.MontyObjectRecognitionExperiment
    config:
      n_train_epochs: 3
  """

  # What Monty's own tests compose an environment or a module from: a group
  # member, with no experiment class and no epochs, sitting under the same
  # directory as the experiments.
  @fragment """
  # @package experiment.config.environment
  env_init_args:
    agents: []
  """

  describe "what Monty ships as an experiment" do
    test "counts the files that name an experiment class, and only those" do
      dir = conf_dir([{"real_experiment", @experiment}, {"test/a_fragment", @fragment}])

      assert Catalog.experiments(conf_dir: dir) |> Enum.map(& &1.name) == ["real_experiment"]
    end

    test "keeps the class and the config of the ones it counts" do
      dir = conf_dir([{"real_experiment", @experiment}])

      assert [experiment] = Catalog.experiments(conf_dir: dir)
      assert experiment.experiment_class =~ "MontyObjectRecognitionExperiment"
      assert experiment.config["n_train_epochs"] == 3
    end
  end

  describe "which experiment writes a memory" do
    test "is the run whose name the memory carries, not the file that configures it" do
      # `tutorial/surf_agent_2obj_train` files what it learns as
      # `surf_agent_1lm_2obj_train` — the name the evaluation config reads. A
      # lookup by file name would answer "nothing trains this" about a memory one
      # press would produce.
      assert Catalog.trainer_for("surf_agent_1lm_2obj_train") == "tutorial/surf_agent_2obj_train"
    end

    test "is nobody when no run is named after the memory" do
      # The models Monty published come out of an archive; no config here trains
      # one, and the page that offers the archives is where a reader looks.
      assert Catalog.trainer_for("pretrained_ycb_v14") == nil
      assert Catalog.trainer_for(nil) == nil
    end
  end
end
