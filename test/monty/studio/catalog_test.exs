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
    - /monty: graph
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
      # A run files what it learns under its `logging.run_name`, which need not
      # be the config file's name: `dogs/mine` here writes `a_memory_name`. A
      # lookup by file name would answer "nothing trains this" about a memory
      # one press would produce. (Monty's own tutorial used to show the two
      # differing; since v0.60.0 its run is named after its file, so the
      # property is pinned on a fixture of ours.)
      dir =
        conf_dir([
          {"dogs/mine",
           String.replace(
             @experiment,
             "n_train_epochs: 3",
             "n_train_epochs: 3\n    logging:\n      run_name: a_memory_name"
           )}
        ])

      assert Catalog.trainer_for("a_memory_name", conf_dir: dir) == "dogs/mine"
      assert Catalog.trainer_for("mine", conf_dir: dir) == nil
    end

    test "is nobody when no run is named after the memory" do
      # The models Monty published come out of an archive; no config here trains
      # one, and the page that offers the archives is where a reader looks.
      assert Catalog.trainer_for("pretrained_ycb_v14") == nil
      assert Catalog.trainer_for(nil) == nil
    end
  end

  describe "a catalogue read from more than one root" do
    test "lists what either root holds" do
      ours = conf_dir([{"dogs/mine", @experiment}])
      montys = conf_dir([{"base", @experiment}])

      names = Catalog.experiments(conf_dir: [ours, montys]) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["base", "dogs/mine"]
    end

    test "answers a name both roots hold from the first" do
      ours =
        conf_dir([
          {"shared", String.replace(@experiment, "n_train_epochs: 3", "n_train_epochs: 7")}
        ])

      montys = conf_dir([{"shared", @experiment}])

      assert [%{config: %{"n_train_epochs" => 7}}] = Catalog.experiments(conf_dir: [ours, montys])
    end

    test "offers a group option from either root, once each" do
      ours = conf_dir([{"dogs/mine", @experiment}])
      montys = conf_dir([{"base", @experiment}])

      for {dir, options} <- [{ours, ["surface_curvature"]}, {montys, ["surface"]}] do
        File.mkdir_p!(Path.join(dir, "termination"))

        for option <- options do
          File.write!(Path.join([dir, "termination", option <> ".yaml"]), "defaults: []\n")
        end
      end

      File.write!(Path.join([montys, "termination", "surface_curvature.yaml"]), "defaults: []\n")

      assert Catalog.options("termination", conf_dir: [ours, montys]) == [
               "surface",
               "surface_curvature"
             ]
    end

    test "re-reads the list when a set adds an experiment" do
      ours = conf_dir([{"dogs/mine", @experiment}])
      montys = conf_dir([{"base", @experiment}])

      assert length(Catalog.experiments(conf_dir: [ours, montys])) == 2

      # A stamp of Monty's tree alone would answer this from before the file
      # existed, which is a page that hides an experiment somebody just added.
      File.write!(Path.join([ours, "experiment/dogs/added.yaml"]), @experiment)

      assert length(Catalog.experiments(conf_dir: [ours, montys])) == 3
    end
  end
end
