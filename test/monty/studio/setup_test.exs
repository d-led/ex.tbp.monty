defmodule Monty.Studio.SetupTest do
  use ExUnit.Case, async: true

  alias Monty.Experiment.SensorModule.ExperimentSensorModule
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching
  alias Monty.Frameworks.Models.Salience.SensorModule.SalienceSM
  alias Monty.Frameworks.Models.SensorModules.{CameraSM, FeatureChangeFilter}
  alias Monty.Frameworks.Models.TwoDSensorModule
  alias Monty.SensorModules.SensorModule
  # The Habitat class is still in the map until the sweep that removes it; the
  # specs below name it as a string, so no alias is needed.
  alias Monty.Simulators.Synthetic
  alias Monty.Studio.{Finding, Setup}
  alias Monty.Test.Tmp

  # The four connectivity rules below are Monty's own: `MontyBase.__init__`
  # refuses to build a model that breaks them. Each test says what Monty says,
  # in the same order, and builds the config from Monty's groups so the fixture
  # is a real config rather than a map shaped like one.

  defp setup_for(name, options \\ []), do: elem(Setup.from_experiment(name, options), 1)

  # The orientation an episode is shown at, as the sampler a config names gives
  # it: Euler angles in degrees, which is how a config writes a pose.
  defp pose(setup, options) do
    episode = Keyword.fetch!(options, :episode)
    params = Setup.object_params(setup, episode, Keyword.put_new(options, :phase, :train))

    params["euler_rotation"]
  end

  describe "the default world" do
    # A run that says nothing steps Monty's own simulator: this build carries it
    # (`priv/monty_py`), so there is nothing to install and nothing to configure.
    # The stand-in is something a run chooses.
    test "is MuJoCo, so an experiment's own world steps it" do
      Tmp.app_env(:world_simulator, nil)

      assert setup_for("tutorial/first_experiment").world == :mujoco
    end

    test "is what the run asked for, instead" do
      Tmp.app_env(:world_simulator, nil)

      assert setup_for("tutorial/first_experiment", world_simulator: :synthetic).world ==
               :synthetic
    end
  end

  # `config:` with nothing under it would wipe the groups' `monty_config` on the
  # way through the composer, which is a fixture bug and not the thing under
  # test, so it is only written when there is something to write.
  defp config_with(groups, config) do
    defaults = Enum.map_join(groups, "\n", fn {group, option} -> "  - /#{group}: #{option}" end)

    body =
      case config do
        empty when empty == %{} ->
          ""

        config ->
          "  config:\n" <>
            Enum.map_join(config, "\n", fn {key, value} -> "    #{key}: #{value}" end)
      end

    """
    # @package _global_

    defaults:
    #{defaults}

    experiment:
      _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
    #{body}
    """
  end

  defp setup_from(groups, config \\ %{}) do
    {:ok, setup} = Setup.from_text(config_with(groups, config))
    setup
  end

  defp errors(setup), do: setup.findings |> Finding.at(:error) |> Enum.map(& &1.code)
  defp warnings(setup), do: setup.findings |> Finding.at(:warning) |> Enum.map(& &1.code)

  @base %{
    "monty" => "graph_exp1000_e3_t3",
    "monty/motor_system_config" => "distant_5",
    "monty/learning_module" => "evidence_1lm_nn5_dod003",
    "monty/sensor_module" => "camera_dist_delta_salience",
    "monty/connectivity" => "1lm_1sm",
    "environment" => "habitat_dist_agent_semantics1",
    "termination" => "any1_objectrecognition_t1000_e500_tot6000",
    "logging" => "silent_warning_train",
    "telemetry" => "warning"
  }

  describe "the phases a run is" do
    # `n_train_epochs` is not the question "does this train": this config names
    # three train epochs and switches training off (`do_train: false`), so a page
    # that read the count announced a phase the experiment never runs.
    test "a config that only evaluates does not train" do
      setup = setup_for("base_config_10distinctobj_dist_agent")

      assert Setup.do_eval(setup)
      refute Setup.do_train(setup)
      assert Setup.epoch_plan(setup) == [{:eval, 14}]
    end

    test "a training config trains, and does not evaluate" do
      setup = setup_for("tutorial/first_experiment")

      assert Setup.do_train(setup)
      refute Setup.do_eval(setup)
      assert Setup.epoch_plan(setup) == [{:train, 1}]
    end

    test "train epochs come before eval ones, as Monty's run() does them" do
      # No shipped config does both; the order is Monty's, and the pairs are
      # what a run steps.
      setup = %{
        setup_for("base_config_10distinctobj_dist_agent")
        | phases: %{train: true, eval: true}
      }

      assert Setup.epoch_plan(setup) == [{:train, 3}, {:eval, 14}]
    end

    test "the termination says how long one episode of each mode may be" do
      setup = setup_for("base_config_10distinctobj_dist_agent")

      assert Setup.max_steps(setup, :eval) == 500
      assert Setup.max_steps(setup, :train) == 1000
      assert setup.termination.max_total_steps == 6000
    end

    test "a config that names no policy says so rather than inventing a limit" do
      setup = %{setup_for("tutorial/first_experiment") | termination: %{}}

      assert Setup.max_steps(setup, :eval) == nil
    end
  end

  describe "reading a real experiment" do
    test "Monty's one-sensor, one-module experiment reads as one of each" do
      setup = setup_for("tutorial/first_experiment")

      assert Enum.map(setup.sensors, & &1.id) == ["patch", "view_finder"]
      assert Enum.map(setup.learning_modules, & &1.id) == ["learning_module_0"]
      assert Enum.any?(setup.connections, &(&1.kind == :sensor_input))
    end

    test "a hierarchy reads as votes between learning modules" do
      setup = setup_for("randrot_noise_10distinctobj_5lms_dist_agent")

      assert length(setup.learning_modules) == 5

      assert setup.connections
             |> Enum.filter(&(&1.kind == :vote))
             |> length() == 20
    end

    test "a config that declares no vote matrix has no vote round" do
      # `lm_to_lm_vote_matrix: null` is what most single-module configs say, and
      # Monty skips `_vote` entirely for them: no vote, and nothing written about
      # votes in the step's report.
      setup = setup_for("base_config_10distinctobj_dist_agent")

      assert Map.get(setup, :vote_round?) == false
      assert Setup.model_spec(setup, :model).lm_to_lm_vote == nil
    end

    test "a hierarchy's votes reach the runtime as one entry per module" do
      setup = setup_for("randrot_noise_10distinctobj_5lms_dist_agent")

      assert %{"learning_module_0" => sources} =
               Setup.model_spec(setup, :model).lm_to_lm_vote

      assert length(sources) == 4
    end

    test "the environment is the simulator plus the interface that makes episodes" do
      setup = setup_for("tutorial/first_experiment")

      assert setup.environment.module.class
      assert setup.environment.interface.class
    end

    test "a MuJoCo config names no objects: its simulator loads the YCB set" do
      setup = setup_for("tutorial/first_experiment")

      assert setup.environment.objects == []
      assert setup.environment.data_path =~ "mujoco/objects/ycb"
    end

    test "the agent starts where the experiment starts it, with its sensors on it" do
      setup = setup_for("base_10simobj_surf_agent")

      assert setup.scene.agent.position == [0.0, 1.5, 0.1]
      # On the agent, in the agent's frame: that is how Monty's proprioception
      # reports a sensor, and how the world composes one into the scene.
      assert setup.scene.sensors["patch"].position == [0.0, 0.0, 0.0]
      assert setup.scene.sensors["view_finder"].position == [0.0, 0.0, 0.03]
    end

    test "a MuJoCo config names no object place: the interface's sampler does" do
      # `Predefined` and `RandomRotation` both default to `(0.0, 1.5, 0.0)` — the
      # same y the agent stands at, ten centimetres nearer the floor. The origin
      # is not that place, and an object a metre and a half away is a surface a
      # surface agent's five-centimetre reach never touches.
      setup = setup_for("base_10simobj_surf_agent")

      assert setup.scene.objects == [%{name: nil, position: [0.0, 1.5, 0.0]}]
    end

    test "each sensor's camera is the one the experiment's agent declares" do
      setup = setup_for("base_10simobj_surf_agent")

      assert setup.cameras["patch"] == [resolution: {64, 64}, zoom: 10.0, hfov: 90.0]
      assert setup.cameras["view_finder"] == [resolution: {64, 64}, zoom: 1.0, hfov: 90.0]
    end

    test "a config that declares no agent has no cameras to render through" do
      setup = Setup.new(%{"experiment" => %{"config" => %{}}})

      assert setup.cameras == %{}
    end

    test "a config Monty ships and this port can run has no errors" do
      setup = setup_for("base_config_10distinctobj_dist_agent")

      assert Setup.valid?(setup), "expected no errors, got #{inspect(errors(setup))}"
    end
  end

  describe "the connectivity Monty insists on" do
    test "a model without sm_to_lm_matrix is refused" do
      setup = setup_from(Map.delete(@base, "monty/connectivity"))

      assert :sm_to_lm_matrix_missing in errors(setup)
    end

    test "the matrix needs a row per learning module" do
      # Two learning modules, wired as if there were one.
      setup = setup_from(Map.put(@base, "monty/learning_module", "displacement_5lm"))

      assert :learning_module_count_mismatch in errors(setup)
    end

    test "every sensor module needs exactly one agent" do
      setup =
        Setup.from_text("""
        # @package _global_

        defaults:
          - /monty: graph_exp1000_e3_t3
          - /monty/learning_module: evidence_1lm_nn5_dod003
          - /monty/sensor_module: camera_dist_delta_salience

        experiment:
          _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
          config:
            monty_config:
              sm_to_agent_dict:
                patch: agent_id_0
              sm_to_lm_matrix:
                - [0]
        """)
        |> elem(1)

      assert :sensor_agent_mapping_mismatch in errors(setup)
    end

    test "a wire to a module that does not exist is reported, not crashed on" do
      setup =
        Setup.from_text("""
        # @package _global_

        defaults:
          - /monty: graph_exp1000_e3_t3
          - /monty/learning_module: evidence_1lm_nn5_dod003
          - /monty/sensor_module: camera_dist_delta_salience

        experiment:
          _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
          config:
            monty_config:
              sm_to_agent_dict:
                patch: agent_id_0
                view_finder: agent_id_0
              sm_to_lm_matrix:
                - [0, 7]
        """)
        |> elem(1)

      assert :connection_index_out_of_range in errors(setup)
    end
  end

  describe "the mistakes Monty would only find later" do
    test "a sensor no learning module matches on is not raised as a mistake" do
      setup = setup_for("tutorial/first_experiment")

      # `first_experiment`'s view finder feeds no learning module, which is how
      # that experiment is written — not a mistake, and not something to warn
      # about. Nothing to say is the answer.
      refute :sensor_unconnected in warnings(setup)
      refute :sensor_not_matched in Enum.map(setup.findings, & &1.code)
    end

    test "a feature the sensor does not produce is called out" do
      setup =
        Setup.from_text("""
        # @package _global_

        defaults:
          - /monty: graph_exp1000_e3_t3
          - /monty/learning_module: evidence_1lm_nn5_dod003
          - /monty/sensor_module: camera_dist_delta_salience
          - /monty/connectivity: 1lm_1sm

        experiment:
          _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
          config:
            monty_config:
              sm_to_agent_dict:
                patch: agent_id_0
                view_finder: agent_id_0
              sm_to_lm_matrix:
                - [0]
              learning_modules:
                learning_module_0:
                  _target_: tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM
                  feature_weights:
                    patch:
                      not_a_feature: 1
              sensor_modules:
                sensor_module_0:
                  _target_: tbp.monty.frameworks.models.sensor_modules.CameraSM
                  sensor_module_id: patch
                  features:
                    - hsv
                sensor_module_1:
                  _target_: tbp.monty.frameworks.models.sensor_modules.CameraSM
                  sensor_module_id: view_finder
                  features:
                    - hsv
        """)
        |> elem(1)

      assert :feature_not_provided in warnings(setup)
    end
  end

  describe "what is ported" do
    test "an experiment built from classes this port has not written is refused" do
      # `test/base_config/base_mujoco` is the example: it names Monty's own test
      # fakes, which live in Monty's `tests/` tree and so are not in the module
      # map at all — a class nobody can place, which nothing can stand in for.
      setup = setup_for("test/base_config/base_mujoco")

      assert [sensor, learning_module] =
               for(%{code: :unknown_module_class} = finding <- setup.findings, do: finding)

      # An error, not an info: no stand-in runs in place of a class this port
      # has not written, so the page disables the run and the task refuses it.
      assert sensor.level == :error
      assert sensor.message =~ "cannot run here"
      assert sensor.where =~ "FakeSensorModule"
      assert learning_module.where =~ "FakeLearningModule"
      refute sensor.message =~ "MuJoCoSimulator"

      refute Setup.valid?(setup)
    end

    test "the tutorial's experiment names only classes this port has written" do
      # This config used to be the describe block's example of a refusal: its
      # learning module and then its supervising experiment class were missing.
      # Both are written, so nothing about its *classes* refuses it now. What is
      # left is about the world it would step — a supervised episode reads the
      # object off the world, and whether a machine has that world is another
      # question (`:no_target_to_supervise`, the object's meshes).
      setup = setup_for("tutorial/first_experiment")

      refute Enum.any?(
               setup.findings,
               &(&1.code in [:modules_not_ported, :learning_module_not_buildable])
             )

      assert [learning_module] = setup.learning_modules
      assert learning_module.module.class == "DisplacementGraphLM"
      assert setup.experiment_class.class == "MontySupervisedObjectPretrainingExperiment"
    end

    test "an experiment that trains on one list and evaluates another walks both" do
      # `test/evidence_lm/evidence_mujoco` names two objects for training and one
      # for evaluation. Monty builds an interface per phase and walks the one for
      # the mode it is in; a run here that walked the evaluation list in both
      # would be half the experiment — and its second training object would never
      # be shown at all.
      setup = setup_for("test/evidence_lm/evidence_mujoco")

      assert Setup.objects(setup, :train) == ["capsule3DSolid", "cubeSolid"]
      assert Setup.objects(setup, :eval) == ["capsule3DSolid"]

      # Two objects for three epochs, then one for three: nine episodes, and a
      # budget of three would stop the run in the middle of its training.
      assert Setup.epoch_plan(setup) == [{:train, 3}, {:eval, 3}]
      assert Setup.planned_episodes(setup) == 9
      assert Setup.episodes(setup) == 9

      # What an episode is built from — the world it shows, the object in it —
      # is its own phase's list.
      assert Setup.object_name(Setup.with_phase(setup, :train), 1) == "cubeSolid"
      assert Setup.object_name(Setup.with_phase(setup, :eval), 1) == "capsule3DSolid"
    end

    test "a config's sampler turns the object from one epoch to the next" do
      setup = setup_for("test/evidence_lm/evidence_mujoco")

      # Monty's `Predefined` defaults to `[(0, 0, 0), (45, 0, 0)]` one per epoch,
      # and a training epoch visits every object once — so the second epoch sees
      # both objects turned, which is what makes it a second graph.
      assert pose(setup, epoch: 0, episode: 0) == [0.0, 0.0, 0.0]
      assert pose(setup, epoch: 0, episode: 1) == [0.0, 0.0, 0.0]
      assert pose(setup, epoch: 1, episode: 0) == [45.0, 0.0, 0.0]
      assert pose(setup, epoch: 1, episode: 1) == [45.0, 0.0, 0.0]
      assert pose(setup, epoch: 2, episode: 1) == [0.0, 0.0, 0.0]
    end

    test "a config that names no sampler leaves the object where the scene put it" do
      # `test/run_mujoco`'s interface names none: the object stays where the
      # scene places it, in every episode, which is what every experiment this
      # port ran before the samplers were written did.
      setup = setup_for("test/run_mujoco")

      assert Setup.object_params(setup, 0, epoch: 1, phase: :train) == nil
    end

    test "an experiment that trains is not refused for training" do
      setup = setup_for("surf_agent_unsupervised_10distinctobj")

      # A training phase hands each episode the memory the last one wrote
      # (`Jobs.Run.end_episode/4`), so training is not a gap a finding stands in
      # for: the config is one this application runs, and the run is its plan.
      assert Setup.valid?(setup)
      assert Setup.epoch_plan(setup) == [{:train, 10}]
    end

    test "and does not explain itself where Monty's code is what runs" do
      {:ok, setup} =
        Setup.from_experiment("tutorial/first_experiment", world_simulator: :mujoco)

      # The MuJoCo classes a run executes are Monty's design, carried out by
      # this application's own Python: neither a stand-in nor a fact a reader of
      # the run needs, so nothing is said about them at all.
      stand_ins = Enum.find(setup.findings, &(&1.code == :modules_not_ported))

      refute stand_ins && stand_ins.message =~ "MuJoCoSimulator"
      refute :modules_run_from_monty in Enum.map(setup.findings, & &1.code)
    end

    test "and warns that a run without Monty's world does not produce Monty's numbers" do
      setup = setup_for("tutorial/first_experiment")

      assert [world] =
               for(%{code: :world_is_a_stand_in} = finding <- setup.findings, do: finding)

      assert world.level == :warning

      # The finding says why the run is a stand-in — no interpreter — and both
      # ways out: configuring one, which makes it the default, or choosing it
      # for one run.
      assert world.message =~ "not the experiment's"
      assert world.message =~ "stand-in scene"
      assert world.message =~ "Choose MuJoCo"
    end

    test "and says nothing about the world when Monty's own is what a run steps" do
      {:ok, setup} = Setup.from_experiment("tutorial/first_experiment", world_simulator: :mujoco)

      refute :world_is_a_stand_in in Enum.map(setup.findings, & &1.code)
    end

    test "and refuses a config whose world is another simulator, before a run starts" do
      # A MuJoCo run of a Habitat config cannot be the experiment: the scene is
      # images another program rendered, and there is no mesh to place. Saying so
      # here disables the run; leaving it to `Setup.world/3` would raise inside
      # the job and leave a failed record for a config the page offered.
      {:ok, setup} = Setup.from_experiment("test/evidence_lm/evidence", world_simulator: :mujoco)

      assert [world] = for(%{code: :world_not_carried} = f <- setup.findings, do: f)

      assert world.level == :error
      assert world.message =~ "HabitatEnvironment"
      assert world.message =~ "stand-in scene"
      refute Setup.valid?(setup)

      # The stand-in scene is a world this build steps, so the same config is
      # offered there — as a stand-in run, which the page says out loud.
      {:ok, stand_in} =
        Setup.from_experiment("test/evidence_lm/evidence", world_simulator: :synthetic)

      refute :world_not_carried in Enum.map(stand_in.findings, & &1.code)
    end

    test "and says separately that Monty's model and experiment loop are this port's own" do
      setup = setup_for("tutorial/first_experiment")

      assert [shell] =
               for(%{code: :modules_not_ported_shell} = finding <- setup.findings, do: finding)

      assert shell.level == :info
      assert shell.message =~ "MontyForGraphMatching"
      assert shell.message =~ "replaced here, not missing"
      assert shell.message =~ "Monty.Studio.Run"
    end

    test "a class this port has written is reported as ported" do
      assert %{status: :implemented, elixir: "Monty.Cmp.Message"} =
               Setup.describe_target("tbp.monty.cmp.Message")
    end

    test "a class Monty ships but this port has not written yet is planned" do
      assert %{status: :planned} =
               Setup.describe_target("tbp.monty.simulators.habitat.agents.HabitatAgent")
    end

    test "Monty's HabitatEnvironment is this port's class, out of process" do
      assert %{
               status: :implemented,
               elixir: "Monty.Simulators.Habitat.Environment.HabitatEnvironment"
             } =
               Setup.describe_target(
                 "tbp.monty.simulators.habitat.environment.HabitatEnvironment"
               )
    end

    test "a target the map does not know is reported as unknown, not guessed" do
      assert %{status: :unknown} = Setup.describe_target("tbp.monty.nonexistent.Thing")
    end
  end

  describe "what a run cannot yet do" do
    test "says nothing about goals when the config's generator is ported" do
      # It is: both of Monty's are, and the module built from the config gets
      # the one it names, so the warning that a run explores without goals has
      # nothing to say.
      refute :goal_generator_not_ported in Enum.map(setup_from(@base).findings, & &1.code)
    end
  end

  describe "the world a run steps" do
    test "is this port's own scene when a run chooses it" do
      assert %Synthetic.Environment{} =
               Setup.world(setup_for("tutorial/first_experiment"), :synthetic)
    end

    test "is Monty's own simulator, hosted here, when a run takes it" do
      # Not a re-implementation: the world is `Monty.Simulators.Mujoco.Environment`,
      # which builds Monty's `MuJoCoSimulator` from `priv/monty_py` in the
      # interpreter this application carries.
      assert %Monty.Simulators.Mujoco.Environment{sensors: sensors} =
               Setup.world(setup_for("tutorial/first_experiment"), :mujoco)

      assert "patch" in sensors
    end

    test "and says which one it is, in words a page can show" do
      # A stand-in scene and Monty's own world are not the same claim about a
      # run, so the page gets two different answers rather than one "world".
      assert Setup.world_name(setup_for("tutorial/first_experiment"), :synthetic) ==
               "stand-in scene (Elixir, one sphere)"

      assert Setup.world_name(setup_for("tutorial/first_experiment"), :mujoco) ==
               "MuJoCo (in this application)"
    end

    test "and refuses an engine this build does not carry, instead of stepping another" do
      setup = setup_for("tutorial/first_experiment", world_simulator: :mujoco)

      # Habitat-Sim is a conda package for another Python and is on its way out
      # of Monty; a config that names it must not be handed MuJoCo's world.
      habitat = %{
        setup
        | environment: %{setup.environment | module: %{class: "HabitatEnvironment"}}
      }

      assert Setup.world_name(habitat) ==
               "HabitatEnvironment (not carried by this application)"

      assert_raise ArgumentError, ~r/does not carry/, fn -> Setup.world(habitat) end
    end

    test "shows the experiment's object to every sensor" do
      world = Setup.world(setup_for("base_10simobj_surf_agent"))

      {observations, _proprioception, _world} = Synthetic.Environment.step(world, [])

      for {sensor_id, observation} <- observations[Synthetic.Environment.agent_id()] do
        assert observation["depth"] |> List.flatten() |> Enum.any?(&(&1 > 0.0)),
               "expected #{sensor_id} to see the object, but every ray missed"
      end
    end
  end

  describe "the model a run starts" do
    test "is the class its config names, when this port has written it" do
      assert Setup.model_class(setup_for("base_config_10distinctobj_dist_agent")) ==
               MontyForEvidenceGraphMatching
    end

    test "and the map reports that class ported, so the page and the run agree" do
      # The setup page's findings are read from the module map and a run starts
      # what `model_class/1` answers; a class in one and not the other is a
      # page that describes a run nobody is running.
      assert %{
               status: :implemented,
               elixir:
                 "Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching"
             } =
               Setup.describe_target(
                 "tbp.monty.frameworks.models.evidence_matching.model.MontyForEvidenceGraphMatching"
               )
    end

    test "is this port's runtime for a config naming a model it has not written" do
      # Not a coercion: the setup page lists that class as this port's own
      # runtime, and a run starting something else would make the page a lie.
      assert Setup.model_class(setup_for("tutorial/first_experiment")) ==
               Monty.Runtime.Model
    end

    test "uses the ported module when the config targets one" do
      setup = setup_from(@base)

      spec = Setup.model_spec(setup, "model_0")

      assert [%{module: EvidenceGraphLM, state: %EvidenceGraphLM{} = lm}] = spec.learning_modules

      # Built from the experiment's own numbers, down to the memory it learns
      # into: those are what make this a run of this experiment.
      assert lm.max_match_distance == 0.01
      assert lm.graph_memory.object_model_options[:max_size] == 0.3
    end

    test "is given the experiment's own step counts, so it cannot conclude early" do
      # Monty requires these of every model: an evaluation that has taken fewer
      # than `min_eval_steps` matching steps is not asked whether it recognised
      # anything. Without them a run asked on its first step and recognised the
      # mug on step 8 of an episode Monty took 43 steps over.
      spec = "base_config_10distinctobj_dist_agent" |> setup_for() |> Setup.model_spec("model_0")

      assert %{min_eval_steps: 20, min_train_steps: 3, num_exploratory_steps: 1000} = spec
    end

    test "waits for its modules for as long as a step takes, as Monty's round does" do
      # A deadline on a module's work decides which module is dropped when the
      # machine is busy, and a dropped module is a step the episode never saw.
      # The vote round keeps its own deadline: that one is an experiment.
      spec = "base_config_10distinctobj_dist_agent" |> setup_for() |> Setup.model_spec("model_0")

      assert spec.call_timeout == :infinity
      refute Map.has_key?(spec, :vote_timeout)
    end

    test "runs the sensor class the config targets, when this port has it" do
      spec = @base |> setup_from() |> Setup.model_spec("model_0")

      assert %{module: CameraSM, state: %CameraSM{} = sensor} =
               Enum.find(spec.sensor_modules, &(&1.id == "patch"))

      # Built from the config's own keys: the features it declared and the filter
      # it asked for.
      assert sensor.features == [
               "pose_vectors",
               "pose_fully_defined",
               "on_object",
               "object_coverage",
               "hsv",
               "principal_curvatures_log"
             ]

      assert {FeatureChangeFilter, %FeatureChangeFilter{}} = sensor.filter
    end

    test "runs each sensor's own class when the config names two of them" do
      # Monty's surf experiments: a patch that is a `CameraSM`, and a view finder
      # that is a transform-pipeline `ExperimentSensorModule` — a camera that
      # measures the scene for the motor system and sends no percept at all.
      spec = "base_10simobj_surf_agent" |> setup_for() |> Setup.model_spec("model_0")

      assert %{module: CameraSM} =
               Enum.find(spec.sensor_modules, &(&1.id == "patch"))

      assert %{module: ExperimentSensorModule, state: %SensorModule{transforms: []}} =
               Enum.find(spec.sensor_modules, &(&1.id == "view_finder"))
    end

    test "runs the salience module a config gives its view finder" do
      # `camera_dist_delta_salience`: a patch that measures the surface, and a
      # view finder that proposes where to look instead — no percept, just goals.
      spec =
        "base_config_10distinctobj_dist_agent" |> setup_for() |> Setup.model_spec("model_0")

      assert %{module: SalienceSM, state: %SalienceSM{sensor_module_id: "view_finder"}} =
               Enum.find(spec.sensor_modules, &(&1.id == "view_finder"))
    end

    test "builds the 2-D sensor module of Monty's three-sensor configurations" do
      # This config used to be the example of a sensor class this port had not
      # written, and got the stand-in. The 2-D module is written, so it is built.
      setup = setup_from(%{@base | "monty/sensor_module" => "3sm_2d3d_dist"})

      spec = Setup.model_spec(setup, "model_0")

      assert Enum.any?(spec.sensor_modules, &match?(%{module: TwoDSensorModule}, &1))
    end

    test "runs the stand-in for a sensor class this port has not written" do
      # Monty's own test suite contributes a fake sensor module to the catalogue;
      # nothing here stands in for it, so the stand-in runs rather than a camera
      # that quietly behaves as if it were one.
      setup = setup_from(%{@base | "monty/sensor_module" => "fake"})

      spec = Setup.model_spec(setup, "model_0")

      assert Enum.any?(spec.sensor_modules, &match?(%{module: Synthetic.SensorModule}, &1))
    end

    test "falls back to the stand-in for a module this port cannot build" do
      # `graph_1lm` names `GraphLM` itself, which has no matching scheme to
      # narrow possible matches with — Monty's base class raises
      # `NotImplementedError` on the second step. The setup is refused rather
      # than run, so the stand-in is never stepped; the spec still has to answer
      # for a config that will be refused.
      setup = setup_from(%{@base | "monty/learning_module" => "graph_1lm"})

      spec = Setup.model_spec(setup, "model_0")

      assert [%{module: Synthetic.LearningModule}] = spec.learning_modules
      assert :learning_module_not_buildable in Enum.map(setup.findings, & &1.code)
      refute Setup.valid?(setup)
    end
  end
end
