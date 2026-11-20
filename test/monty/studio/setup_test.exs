defmodule Monty.Studio.SetupTest do
  # Not async: the default-world cases move `:world_simulator`, which
  # `Monty.Studio.open/2` reads when a setup names no world — a global, so a
  # setup opened beside them would be handed this file's world. The rule is
  # `Tmp.app_env/2`'s.
  use ExUnit.Case, async: false

  alias Monty.Experiment.MatchCriteria.NamedLMsMatch
  alias Monty.Experiment.SensorModule.ExperimentSensorModule
  alias Monty.Experiment.SensorModules.Telemetry.Snapshot
  alias Monty.Frameworks.Environments.TwoDData.OmniglotEnvironment
  alias Monty.Frameworks.Environments.TwoDData.SaccadeOnImageEnvironment
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching
  alias Monty.Frameworks.Models.GraphMatching.GraphLM
  alias Monty.Frameworks.Models.Salience.Segmentation.SlicMerge
  alias Monty.Frameworks.Models.Salience.SensorModule.SalienceSM
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.ColorChannelSalience
  alias Monty.Frameworks.Models.SensorModules.{CameraSM, FeatureChangeFilter}
  alias Monty.Frameworks.Models.TwoDSensorModule
  alias Monty.SensorModules.SensorModule
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
    # A run that names no world steps the compiled binding when this machine can
    # render with it — the same scene as Monty's own simulator, measured at
    # 1.7–1.8× faster per world step — and Monty's interpreter when it cannot,
    # because a default a machine cannot step fails every run the moment somebody
    # uses it.
    test "is what the node can step: the compiled binding when it can render" do
      Tmp.app_env(:world_simulator, nil)

      expected = if Monty.Simulators.ExMujoco.World.available?(), do: :ex_mujoco, else: :mujoco

      assert Monty.Studio.Setup.default_world() == expected
      assert setup_for("tutorial/first_experiment").world == expected
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
    "environment" => "mujoco_dist_agent_semantics1",
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

    # Monty's noisier configs name a `MinEvalMaxTotalSteps` that wraps an `Any` of
    # a `StepLimit` and a `MatchCriteria`, and the per-mode limits are on the
    # wrapped `StepLimit`. Reading only the outer block found the ceiling and lost
    # them, so such an experiment had no limit of its own and a page invented one.
    test "a composite policy's per-mode limits are read through its wrapper" do
      setup = setup_for("randrot_noise_10distinctobj_dist_agent")

      assert Setup.max_steps(setup, :eval) == 500
      assert Setup.max_steps(setup, :train) == 1000
      assert Setup.max_total_steps(setup) == 6000
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

    # The other way a config names its cameras: one sensor at a time in an
    # `agents` map, with the resolutions and the zooms in the agent's own sensor
    # order rather than beside each sensor. A sensor with no resolution of its
    # own is a sensor with no camera — there is nothing to render through.
    test "agents named as a map keep their sensors' resolution and zoom by position" do
      setup =
        Setup.new(%{
          "experiment" => %{
            "config" => %{
              "environment" => %{
                "env_init_args" => %{
                  "agents" => %{
                    "agent_args" => %{
                      "sensor_ids" => ["patch", "view_finder", "unresolved"],
                      "resolutions" => [[64, 64], [128, 96]],
                      "zooms" => [10.0]
                    }
                  }
                }
              }
            }
          }
        })

      assert setup.cameras == %{
               "patch" => [resolution: {64, 64}, zoom: 10.0, hfov: 90.0],
               "view_finder" => [resolution: {128, 96}, zoom: 1.0, hfov: 90.0]
             }
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

  describe "the match criterion a termination config names" do
    # Monty's experiment reads `match_criterion` from the same config group as
    # the recognition strategy and sets it on the model before the first
    # episode. A config that names `NamedLMsMatch` must not run to the model's
    # own default, which is a different notion of recognition.
    test "reaches the model, instead of the default" do
      setup =
        setup_from(Map.put(@base, "termination", "named_lm2_objectrecognition_t1000_e100_tot500"))

      named = {NamedLMsMatch, %NamedLMsMatch{ids: MapSet.new(["learning_module_2"])}}

      assert setup.match_criterion == named
      assert Setup.model_spec(setup, :criterion_test).match_criterion == named
    end

    test "a criterion that cannot be built is refused, not silently replaced" do
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
            match_criterion:
              _target_: tbp.monty.experiment.match_criteria.AnyLMsMatch
              count: 0
        """)
        |> elem(1)

      assert :match_criterion_not_readable in errors(setup)
      assert setup.match_criterion == nil
    end
  end

  describe "the attention system" do
    # The cows experiments name `monty/attention_system: default`. Monty pools
    # the goals into 5 mm voxels and filters them, so a run that ignored it would
    # be a different experiment wearing the same config's name.
    test "a config that names the default system gets Monty's voxel grid" do
      setup = setup_from(Map.put(@base, "monty/attention_system", "default"))

      assert {Monty.Attention.AttentionSystem.DefaultAttentionSystem, system} =
               Setup.model_spec(setup, "model").attention

      assert system.voxel_size == 0.005
    end

    test "a config that names no attention system gets Monty's no-op, and every goal passes" do
      assert {Monty.Attention.AttentionSystem.NoopAttentionSystem, system} =
               Setup.model_spec(setup_from(@base), "model").attention

      goals = [%Monty.Cmp.Goal{sender_id: "lm_0", sender_type: :gsg}]

      assert {_system, ^goals} =
               Monty.Attention.AttentionSystem.NoopAttentionSystem.step(system, goals, [])
    end
  end

  describe "a sensor module" do
    # A sensor is built from its class *and the classes its own config names*. Two
    # things went wrong here: `SalienceSM.from_config/2` refused a layer this port
    # had not written and nothing recorded it, so `Setup` built the stand-in sensor
    # instead — and the cows family's view finder, which names a `Vocus2` strategy
    # and a `SlicMerge` segmentation, then ran episodes that proposed no goals and
    # concluded nothing while looking healthy.
    test "is the config's own, with the strategy and segmentation it names" do
      setup = setup_for("base_infer_cows_small_compositional", world_simulator: :mujoco)

      refute :sensor_module_not_buildable in errors(setup)

      view_finder =
        Enum.find(Setup.model_spec(setup, "cows").sensor_modules, &(&1.id == "view_finder"))

      assert view_finder.module == SalienceSM

      assert {Vocus2, %Vocus2{color: %ColorChannelSalience{center_sigma: 1.0}}} =
               view_finder.state.salience_strategy

      assert {SlicMerge, %SlicMerge{}} = view_finder.state.segmentation_strategy
    end

    # The refusal is still what happens to a sensor whose layers are missing: a
    # run that stepped a stand-in would measure something else than the config
    # describes, which is the failure this rule exists for.
    test "that names a layer this port has not written is refused, naming it" do
      setup =
        Setup.from_text("""
        # @package _global_

        defaults:
          - /monty: graph_exp1000_e3_t3
          - /monty/learning_module: evidence_1lm_nn5_dod003
          - /environment: mujoco_ycb_dist_agent

        experiment:
          _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
          config:
            monty_config:
              sensor_modules:
                view_finder:
                  _target_: tbp.monty.frameworks.models.salience.sensor_module.SalienceSM
                  sensor_module_id: view_finder
                  segmentation_strategy:
                    _target_: tbp.monty.frameworks.models.salience.segmentation.some_watershed.SomeWatershed
        """)
        |> elem(1)

      assert :sensor_module_not_buildable in errors(setup)

      [finding] = Enum.filter(setup.findings, &(&1.code == :sensor_module_not_buildable))

      assert finding.message =~ "view_finder"
      assert finding.message =~ "SomeWatershed as its segmentation_strategy"
      assert finding.message =~ "stand-in sensor"
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
    # `test/base_config/base` names Monty's own test doubles, which live in
    # Monty's `tests/` tree and so are not in the module map at all. Nothing is
    # missing here that anybody means to write, so the finding says which kind of
    # gap it is rather than pointing at the port.
    test "a config built from Monty's test doubles is refused, and says why" do
      setup = setup_for("test/base_config/base")

      assert [sensor, learning_module] =
               for(%{code: :test_fixture_class} = finding <- setup.findings, do: finding)

      # An error, not an info: no stand-in runs in place of a class the map cannot
      # place, so the page disables the run and the task refuses it.
      assert sensor.level == :error
      assert sensor.message =~ "Monty's own test suite"
      assert sensor.where =~ "FakeSensorModule"
      assert learning_module.where =~ "FakeLearningModule"

      refute Setup.valid?(setup)
    end

    # A class outside the map that is *not* a fixture is a different answer: a
    # typo or a class this port has never heard of, not Monty's test suite asking.
    test "a class nothing can place and that is not a fixture is unknown" do
      setup =
        Setup.from_text("""
        # @package _global_

        defaults:
          - /monty: graph_exp1000_e3_t3
          - /monty/learning_module: evidence_1lm_nn5_dod003

        experiment:
          _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
          config:
            monty_config:
              learning_modules:
                learning_module_0:
                  _target_: tbp.monty.frameworks.models.nowhere.UnknownLM
        """)
        |> elem(1)

      assert [finding] =
               for(%{code: :unknown_module_class} = finding <- setup.findings, do: finding)

      assert finding.where =~ "UnknownLM"

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
      # `test/evidence_lm/evidence` names two objects for training and one
      # for evaluation. Monty builds an interface per phase and walks the one for
      # the mode it is in; a run here that walked the evaluation list in both
      # would be half the experiment — and its second training object would never
      # be shown at all.
      setup = setup_for("test/evidence_lm/evidence")

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
      setup = setup_for("test/evidence_lm/evidence")

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
      # `test/run`'s interface names none: the object stays where the scene
      # places it, in every episode, which is what every experiment this port
      # ran before the samplers were written did.
      setup = setup_for("test/run")

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

    test "the view finder the model gets is the config's, with its transform" do
      setup = setup_for("surf_agent_unsupervised_10distinctobj")

      view_finder =
        Enum.find(Setup.model_spec(setup, "surf").sensor_modules, &(&1.id == "view_finder"))

      assert view_finder.module == ExperimentSensorModule
      assert [{Snapshot, %Snapshot{}}] = view_finder.state.transforms
    end

    test "counts Monty's MuJoCo simulator as ported, because it is" do
      {:ok, setup} =
        Setup.from_experiment("tutorial/first_experiment", world_simulator: :mujoco)

      # The class a config names for the world is written here —
      # `Monty.Simulators.Mujoco.Simulator.MuJoCoSimulator`, whose scene lives in
      # `priv/monty_py/world.py` because a renderer is a C library's Python
      # binding. A port with a different implementation, not a gap, so the count
      # is whole and nothing on the page asks the reader to explain it away.
      assert %{implemented: implemented, total: total} = Setup.ported(setup)
      assert implemented == total

      refute Enum.any?(
               setup.findings,
               &(&1.code in [:modules_not_ported, :modules_not_ported_world])
             )
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

    test "and says nothing about the world of a CAD experiment the CAD scene steps" do
      # The CAD scene is MuJoCo with the part's own meshes, and a CAD
      # experiment's config reads the parts the pipeline wrote — so this is the
      # world the config was written for, not a stand-in. The page used to call
      # it "not carried" and offer MuJoCo, which steps something else.
      {:ok, setup} = Setup.from_experiment("cad/blend_part_eval", world_simulator: :cad)

      refute :world_not_carried in Enum.map(setup.findings, & &1.code)
    end

    test "and warns when the CAD scene is given a config whose objects are not parts" do
      {:ok, setup} = Setup.from_experiment("tutorial/first_experiment", world_simulator: :cad)

      assert [world] = for(%{code: :world_not_carried} = f <- setup.findings, do: f)
      assert world.level == :warning
      assert world.message =~ "results are not the"
    end

    test "and refuses a config whose world is another simulator, before a run starts" do
      # A MuJoCo run of an image config cannot be the experiment: the scene is
      # images another program rendered, and there is no mesh to place. Saying so
      # here disables the run; leaving it to `Setup.world/3` would raise inside
      # the job and leave a failed record for a config the page offered.
      {:ok, setup} =
        Setup.from_experiment("world_image_on_scanned_model", world_simulator: :mujoco)

      assert [world] = for(%{code: :world_not_carried} = f <- setup.findings, do: f)

      assert world.level == :error
      assert world.message =~ "SaccadeOnImageEnvironment"
      assert world.message =~ "stand-in scene"
      refute Setup.valid?(setup)
    end

    test "and no longer says Monty's vote round is this port's own" do
      # The finding used to name `MontyForGraphMatching` as a class replaced by
      # the runtime. Its vote round is ported now
      # (`...GraphMatching.MontyForGraphMatching.combine_votes/2`), so a config
      # of that family is told nothing about a missing loop — the part that is
      # still the runtime's job is the stepping itself.
      setup = setup_for("tutorial/first_experiment")

      shells =
        for(
          %{code: :modules_not_ported_shell} = finding <- setup.findings,
          do: finding.message
        )

      refute Enum.any?(shells, &(&1 =~ "MontyForGraphMatching"))

      assert setup.experiment_class.class == "MontySupervisedObjectPretrainingExperiment"
    end

    test "a class this port has written is reported as ported" do
      assert %{status: :implemented, elixir: "Monty.Cmp.Message"} =
               Setup.describe_target("tbp.monty.cmp.Message")
    end

    test "a class Monty ships but this port has not written yet is planned" do
      assert %{status: :planned} =
               Setup.describe_target(
                 "tbp.monty.frameworks.loggers.wandb_handlers.BasicWandbTableStatsHandler"
               )
    end

    test "a target Monty removed is reported as unknown, not guessed" do
      # Habitat was dropped from Monty in #1286; a config still naming it names
      # nothing this map can place, which is what `:unknown` says.
      assert %{status: :unknown} =
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

    test "is a captured scene when the config is an image experiment" do
      # An image config's world is photographs of objects with the depth the same
      # lens measured, and which one an episode is on is the config's own
      # `eval_env_interface_args`: episode 4 of `world_image_on_scanned_model` is
      # scene 1, version 0, because its lists open `[0, 0, 0, 0, 1, ...]` and
      # `[0, 1, 2, 3, 0, ...]`.
      captures = write_captures(["0_mug", "1_mug"])
      setup = with_captures(setup_for("world_image_on_scanned_model"), captures)

      assert %SaccadeOnImageEnvironment{scene: "1_mug", version: 0} =
               Setup.world(setup, :image, 4)
    end

    test "has as many objects as it has captures, named for the capture each shows" do
      # An image config walks captures, not objects: `scenes: [0, 0, 0, 0, 1, ...]`
      # is four versions of the first capture and then the second, so the fifth
      # episode's object is the second capture's. An empty list would divide an
      # epoch's episode count by nothing.
      captures = write_captures(["0_mug", "1_cup"])
      setup = with_captures(setup_for("world_image_on_scanned_model"), captures)

      objects = Setup.objects(setup, :eval)

      assert length(objects) == 48
      assert Enum.take(objects, 5) == ["mug", "mug", "mug", "mug", "cup"]
    end

    test "refuses a directory that holds no capture, rather than pretending to step it" do
      empty = Path.join(System.tmp_dir!(), "no_captures_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf(empty) end)

      setup = with_captures(setup_for("world_image_on_scanned_model"), empty)

      assert_raise ArgumentError, ~r/holds no scene/, fn ->
        Setup.world(setup, :image, 0)
      end
    end

    test "is a drawing when the config is an Omniglot experiment" do
      # An Omniglot config names three lists — `alphabets`, `characters`,
      # `versions` — and its interface walks them together: episode 3 of
      # `tutorial/omniglot_training` is alphabet 1, character 1, version 1,
      # because both lists open `[0, 0, 0, 1, ...]` and `[1, 2, 3, 1, ...]`.
      setup = with_dataset(setup_for("tutorial/omniglot_training"))

      assert %OmniglotEnvironment{alphabet: "Beta", character_id: 1, character_version: 1} =
               Setup.world(setup, :omniglot, 3, phase: :train)
    end

    test "has as many objects as the config has characters, named for the alphabet each draws" do
      setup = with_dataset(setup_for("tutorial/omniglot_training"))

      objects = Setup.objects(setup, :train)

      assert objects == ["Alpha_1", "Alpha_2", "Alpha_3", "Beta_1", "Beta_2", "Beta_3"]
    end

    test "says the dataset is missing rather than stepping a drawing it does not have" do
      # The dataset is looked for under this machine's data root, so the root is
      # the test's: an empty one is a run whose dataset has not been downloaded,
      # and a directory somebody happens to have keeps nothing out of the report.
      empty = Path.join(System.tmp_dir!(), "no_drawings_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf(empty) end)
      Tmp.system_env("MONTY_DATA", empty)

      setup = setup_for("tutorial/omniglot_training", world_simulator: :omniglot)

      assert :world_data_missing in Enum.map(Setup.findings(setup, :error), & &1.code)

      assert_raise ArgumentError, ~r/holds no alphabet/, fn ->
        Setup.world(setup, :omniglot, 0, phase: :train)
      end
    end

    test "is the world the config was written for, not this node's engine" do
      # A captured scene is its own world: no simulator steps it, so asking this
      # node's MuJoCo to stand in for one is a refusal dressed as a choice. A
      # config that names one starts on it, with no world argument anywhere.
      Tmp.system_env("MONTY_DATA", bright_scenes())

      setup = setup_for("bright_world_image_on_scanned_model")

      assert setup.world == :image
      refute Enum.any?(Setup.findings(setup, :error), &(&1.code in [:world_not_carried]))
      assert %SaccadeOnImageEnvironment{} = Setup.world(setup, :image, 0)
      assert Setup.input_name(setup) =~ "worldimages/bright_scenes"
    end

    test "leaves a MuJoCo config on this node's engine" do
      setup = setup_for("tutorial/first_experiment")

      assert Setup.engine(setup) == :mujoco
      assert setup.world in [:synthetic, :mujoco, :ex_mujoco]
    end

    test "is Monty's own simulator, ported to this build, when a run takes it" do
      # The world is `Monty.Simulators.Mujoco.Simulator.MuJoCoSimulator`, the
      # class the config names, ported: the scene it builds comes from
      # `priv/monty_py`, this application's own script against `mujoco`, in the
      # interpreter it carries.
      assert %Monty.Simulators.Mujoco.Simulator.MuJoCoSimulator{sensors: sensors} =
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

      # The same MuJoCo scene, and the name says what differs: which program
      # steps it.
      assert Setup.world_name(setup_for("tutorial/first_experiment"), :ex_mujoco) ==
               "MuJoCo (compiled in, via ex_mujoco)"
    end

    test "and refuses an engine this build does not carry, instead of stepping another" do
      setup = setup_for("tutorial/first_experiment", world_simulator: :mujoco)

      # Monty still ships worlds this build does not carry — an image stream is
      # one — and a config that names one must not be handed MuJoCo's world.
      uncarried = %{
        setup
        | environment: %{setup.environment | module: %{class: "SaccadeOnImageEnvironment"}}
      }

      assert Setup.world_name(uncarried) ==
               "SaccadeOnImageEnvironment (not carried by this application)"

      assert_raise ArgumentError, ~r/cannot stand in for/, fn -> Setup.world(uncarried) end
    end

    test "shows the experiment's object to every sensor" do
      world = Setup.world(setup_for("base_10simobj_surf_agent"))

      {observations, _proprioception, _world} = Synthetic.Environment.step(world, [])

      for {sensor_id, observation} <- observations[Synthetic.Environment.agent_id()] do
        assert observation["depth"] |> List.flatten() |> Enum.any?(&(&1 > 0.0)),
               "expected #{sensor_id} to see the object, but every ray missed"
      end
    end

    test "offers a world when this node can step it" do
      # A CAD world is offered because this node carries the scene and the parts
      # travel with the application: a desktop install with an empty data
      # directory still steps a part.
      Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
      Tmp.without_env("MONTY_CAD_PART")

      assert List.last(Setup.worlds()) == :cad
      assert Setup.world_name(setup_for("tutorial/first_experiment"), :cad) =~ "parts to choose"
    end

    test "a compiled MuJoCo world refuses a config whose environment is not MuJoCo" do
      setup = setup_for("tutorial/first_experiment", world_simulator: :ex_mujoco)

      uncarried = %{
        setup
        | environment: %{setup.environment | module: %{class: "HabitatEnvironment"}}
      }

      assert_raise ArgumentError, ~r/cannot stand in for/, fn ->
        Setup.world(uncarried, :ex_mujoco)
      end
    end

    test "the compiled MuJoCo world is built from the same numbers as the ported one" do
      setup = setup_for("base_10simobj_surf_agent")

      ported = Setup.world(setup, :mujoco)
      compiled = Setup.world(setup, :ex_mujoco)

      # One spec, two ways of stepping it: what a scene is built from must not
      # depend on which program compiles it.
      assert %{spec: spec} = ported
      assert %{spec: same} = compiled
      assert same == spec
    end

    # A CAD part is stepped by another application's scene (`MontyCad.Scene`),
    # which a studio node need not carry, so the part is asked for by name and
    # the answer here is what such a node says instead of a FunctionClauseError
    # or a world that half-works.
    test "refuses a CAD world when this node holds no part to open" do
      data = Tmp.dir("monty-data")
      Tmp.system_env("MONTY_DATA", data)
      Tmp.without_env("MONTY_CAD_PART")
      setup = setup_for("tutorial/first_experiment")

      assert_raise ArgumentError, ~r/no CAD part is named.*parts/s, fn ->
        Setup.world(setup, :cad)
      end
    end

    # MuJoCo's objects arrive in directories under `MONTY_DATA`; a part is the
    # same kind of input, so it is named the same way and lives beside them.
    # These cases hold the resolution, which is what a page, a run and the CAD
    # server's tools all have to agree about.
    test "a part is a name in this node's data root, not a path in someone's home" do
      data = Tmp.dir("monty-data")
      Tmp.system_env("MONTY_DATA", data)
      Tmp.system_env("MONTY_CAD_PART", "bracket")
      File.mkdir_p!(Path.join(data, "parts"))
      File.write!(Path.join([data, "parts", "bracket.step"]), "")

      assert Setup.cad_part_path() == {:ok, Path.join([data, "parts", "bracket.step"])}
      assert "bracket.step" in Setup.cad_parts()
    end

    test "a name the parts directory does not have says which parts it does" do
      data = Tmp.dir("monty-data")
      Tmp.system_env("MONTY_DATA", data)
      Tmp.system_env("MONTY_CAD_PART", "bracket")

      assert {:error, sentence} = Setup.cad_part_path()
      assert sentence =~ ~s(there is no part "bracket")
      assert sentence =~ "parts"
    end

    test "a path to a file that exists is used as it is, for a one-off part" do
      path = Tmp.file("loose.step")
      File.write!(path, "")
      Tmp.system_env("MONTY_CAD_PART", path)

      assert Setup.cad_part_path() == {:ok, path}
    end

    # A desktop install has no repository beside it, and the parts it can step
    # travel with the application: an empty data root is not an empty CAD world.
    test "opens a part the application ships, with nothing downloaded" do
      Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
      Tmp.without_env("MONTY_CAD_PART")

      assert "solidcraft-plate.step" in Setup.cad_parts()

      Tmp.system_env("MONTY_CAD_PART", "solidcraft-plate")

      assert {:ok, path} = Setup.cad_part_path()
      assert Path.basename(path) == "solidcraft-plate.step"
      assert File.regular?(path)
    end

    # A person who puts their own copy there means it: the data root is searched
    # before the shipped parts, so the file a run opens is the one they placed.
    test "a copy under the node's own data root wins over the shipped one" do
      data = Tmp.dir("monty-data")
      Tmp.system_env("MONTY_DATA", data)
      File.mkdir_p!(Path.join(data, "parts"))
      File.write!(Path.join([data, "parts", "solidcraft-plate.step"]), "mine")

      Tmp.system_env("MONTY_CAD_PART", "solidcraft-plate")

      assert Setup.cad_part_path() ==
               {:ok, Path.join([data, "parts", "solidcraft-plate.step"])}
    end

    test "names the CAD part a run would step, from the deployment" do
      setup = setup_for("tutorial/first_experiment")
      Tmp.system_env("MONTY_CAD_PART", "/parts/bracket.step")

      assert Setup.world_name(setup, :cad) == "CAD part (bracket.step)"
    end

    test "a part is its features when the deployment asks for them" do
      Tmp.system_env("MONTY_CAD_LABELS", "features")
      assert Setup.cad_labels() == :features

      Tmp.without_env("MONTY_CAD_LABELS")
      assert Setup.cad_labels() == :part
    end

    test "says which part a run would open, or how many there are to choose" do
      Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
      setup = setup_for("tutorial/first_experiment")

      Tmp.system_env("MONTY_CAD_PART", "solidcraft-plate")
      assert Setup.world_name(setup, :cad) == "CAD part (solidcraft-plate)"

      Tmp.without_env("MONTY_CAD_PART")
      assert Setup.world_name(setup, :cad) =~ "parts to choose"
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
      setup = setup_from(%{@base | "monty/sensor_module" => "3sm_2d3d_dist_raw0"})

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

    test "builds the base graph module a supervised pretraining config names" do
      # `graph_1lm` names `GraphLM` itself. Monty builds it and trains with it —
      # a supervised episode is handed the object it saw, and nothing is matched
      # — so there is nothing to stand in for and nothing to refuse.
      setup = setup_from(%{@base | "monty/learning_module" => "graph_1lm"})

      spec = Setup.model_spec(setup, "model_0")

      assert [%{module: built}] = spec.learning_modules
      assert built == GraphLM
      refute :learning_module_not_buildable in Enum.map(setup.findings, & &1.code)
    end
  end

  # Two captures, each a colour image and the depth that goes with it, written
  # where the world expects them: a directory per scene, `rgb_<version>.png` and
  # `depth_<version>.data` inside.
  defp write_captures(scenes) do
    path = Path.join(System.tmp_dir!(), "captures_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)

    for scene <- scenes do
      File.mkdir_p!(Path.join(path, scene))
      for version <- 0..1, do: write_capture(Path.join(path, scene), version)
    end

    path
  end

  defp write_capture(scene_path, version) do
    colour =
      for(
        row <- 0..15,
        into: <<>>,
        do: for(column <- 0..15, into: <<>>, do: <<row * 8, column * 8, 128>>)
      )

    depth =
      for(
        row <- 0..15,
        column <- 0..15,
        into: <<>>,
        do: <<0.2 + 0.001 * (row + column)::float-little-32>>
      )

    File.write!(
      Path.join(scene_path, "rgb_#{version}.png"),
      ExTbpMonty.Core.Png.rgb_bytes(colour, 16, 16)
    )

    File.write!(Path.join(scene_path, "depth_#{version}.data"), depth)
  end

  # A data root holding what `bright_world_image_on_scanned_model` reads:
  # `worldimages/bright_scenes` with one capture in it.
  defp bright_scenes do
    root = Path.join(System.tmp_dir!(), "monty_data_#{System.unique_integer([:positive])}")
    scene = Path.join([root, "worldimages", "bright_scenes", "0_numenta_mug"])
    File.mkdir_p!(scene)
    on_exit(fn -> File.rm_rf(root) end)

    write_capture(scene, 0)
    root
  end

  defp with_captures(%Setup{environment: %{data_path: _} = environment} = setup, path) do
    %{setup | environment: %{environment | data_path: path}}
  end

  defp with_captures(setup, _path), do: setup

  # A small Omniglot dataset — two alphabets of three characters — where a drawing
  # world can be pointed at it.
  defp with_dataset(setup) do
    path = OmniglotFixture.write(["Alpha", "Beta"])
    on_exit(fn -> File.rm_rf(path) end)
    with_data_path(setup, path)
  end

  defp with_data_path(%Setup{environment: %{data_path: _} = environment} = setup, path) do
    %{setup | environment: %{environment | data_path: path}}
  end
end
