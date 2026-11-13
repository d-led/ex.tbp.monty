defmodule Monty.Studio.PartitionTest do
  @moduledoc """
  Monty's `run_parallel.py`, as a plan: how an experiment is divided between the
  workers of one press of Run.

  These cases are about the *division* — every episode run once, the rotations of
  an object kept together, and a part's episodes being the experiment's own
  numbers rather than a second numbering starting at zero. Whether a part then
  steps those episodes correctly is `Monty.Studio.Jobs.Run`'s business.
  """

  use ExUnit.Case, async: true

  alias ExTbpMonty.Cluster.Protocol
  alias Monty.Studio
  alias Monty.Studio.{Partition, Setup}

  # Ten objects evaluated fourteen times: a hundred and forty episodes, the
  # config the acceptance ladder runs.
  @evaluation "base_config_10distinctobj_dist_agent"

  # Two objects trained fourteen times, one object per part.
  @training "tutorial/dist_agent_5lm_2obj_train"

  # Trains on two objects three times, then evaluates one object three times:
  # two waves, and the second one reads what the first built.
  @both "test/evidence_lm/evidence"

  # Three training objects, one episode each, and three evaluation objects.
  @three "test/base_config/base"

  setup_all do
    %{
      evaluation: opened(@evaluation),
      training: opened(@training),
      both: opened(@both),
      three: opened(@three)
    }
  end

  defp opened(name) do
    {:ok, opened} = Studio.open(name)
    opened.setup
  end

  describe "an evaluation" do
    test "is cut into as many parts as there are workers, and the parts are the episodes",
         %{evaluation: setup} do
      plan = Partition.plan(setup, 4, nil, batch: "batch")

      assert [%{phase: :eval}, _, _, _] = parts = Partition.parts(plan)
      assert Enum.map(parts, & &1.of) == [4, 4, 4, 4]
      assert Enum.map(parts, & &1.index) == [0, 1, 2, 3]

      # Every episode once, in the experiment's own order: the division is of the
      # work, not a second experiment.
      assert parts |> Enum.flat_map(& &1.episodes) == Enum.to_list(0..139)
      assert parts |> Enum.map(&length(&1.episodes)) == [35, 35, 35, 35]
    end

    test "is not shorter than its work: more workers than episodes is one episode a part",
         %{evaluation: setup} do
      plan = Partition.plan(setup, 8, 3, batch: "batch")

      assert parts = Partition.parts(plan)
      assert length(parts) == 3
      assert Enum.map(parts, & &1.episodes) == [[0], [1], [2]]
      assert Enum.map(parts, & &1.of) == [3, 3, 3]
    end

    test "runs as much of the experiment as the budget says, not all of it", %{
      evaluation: setup
    } do
      plan = Partition.plan(setup, 2, 10, batch: "batch")

      assert parts = Partition.parts(plan)
      assert parts |> Enum.flat_map(& &1.episodes) == Enum.to_list(0..9)
    end

    test "a part is not an episode: one worker takes a stretch of them", %{evaluation: setup} do
      [part | _rest] = Partition.parts(Partition.plan(setup, 2, 10, batch: "batch"))

      assert part.episodes == [0, 1, 2, 3, 4]
    end
  end

  describe "a training" do
    test "keeps an object's rotations together and in order, one object a part", %{
      training: setup
    } do
      plan = Partition.plan(setup, 4, nil, batch: "batch")

      # Two objects, so two parts however many workers were asked for: an object
      # is not divisible, because every rotation extends the graph the one
      # before it built.
      assert [first, second] = parts = Partition.parts(plan)
      assert Enum.map(parts, & &1.of) == [2, 2]

      # Episode 0 is object 0 in the first rotation, episode 1 object 1, and so
      # on — so a part's numbers are every other number of the experiment.
      assert first.episodes == Enum.to_list(0..27//2)
      assert second.episodes == Enum.to_list(1..27//2)
      assert parts |> Enum.flat_map(& &1.episodes) |> Enum.sort() == Enum.to_list(0..27)
    end

    test "fewer workers than objects means a part takes objects in turn", %{three: setup} do
      # Three training objects and two workers: each object is still trained by
      # exactly one part, and the third object goes to the first part because
      # the parts alternate.
      [first, second] = Partition.plan(setup, 2, nil, batch: "batch").train

      assert first.episodes == [0, 2]
      assert second.episodes == [1]
    end
  end

  describe "a config that trains and then evaluates" do
    test "is two waves, and the evaluation is what waits for the training to be merged", %{
      both: setup
    } do
      plan = Partition.plan(setup, 2, nil, batch: "batch")

      assert Partition.two_waves?(plan)
      assert Enum.map(plan.train, & &1.phase) == [:train, :train]
      assert Enum.map(plan.eval, & &1.phase) == [:eval, :eval]

      # Training first, in the order the waves run.
      assert Partition.parts(plan) == plan.train ++ plan.eval
    end

    test "an evaluation-only config is one wave", %{evaluation: setup} do
      refute Partition.two_waves?(Partition.plan(setup, 2, nil, batch: "batch"))
    end
  end

  describe "the phases an experiment runs" do
    test "are the episodes of Monty's run_epoch, per phase", %{both: setup} do
      # Two objects trained three times, then one object evaluated three times.
      assert Setup.epoch_plan(setup) == [{:train, 3}, {:eval, 3}]
      assert Partition.episodes(setup, :train) == 6
      assert Partition.episodes(setup, :eval) == 3
    end

    test "a phase the config switches off has no parts", %{training: setup} do
      plan = Partition.plan(setup, 2, nil, batch: "batch")

      refute Setup.do_eval(setup)
      assert plan.eval == []
    end
  end

  # A part's steps are a file in the run's own directory, written by whoever
  # performed it and read by the node that owns the run. So a part may only be
  # given to a node that writes that directory, can step what the run needs, and
  # runs this build — and the division of a symmetric cluster is that list, split
  # as evenly as it goes.
  describe "where each part is performed" do
    setup do
      parts = [
        %{index: 0, of: 2, phase: :eval, episodes: [0]},
        %{index: 1, of: 2, phase: :eval, episodes: [1]}
      ]

      {:ok, parts: parts}
    end

    test "every part stays here when no peer writes the run's files where this node reads them",
         %{parts: parts} do
      here = entry("node1", self: true)
      elsewhere = entry("node2", artifacts: "/somewhere/else")
      silent = entry("node3", artifacts: nil)

      assert [{_, [first]}, {_, [second]}] =
               Partition.hosts(parts, [here, elsewhere, silent], ["monty"])

      assert first.self
      assert second.self
    end

    # Each part is given an ordered list, and the first of it is where the part
    # goes: the rest are where it goes if that node stops answering, which is how
    # a lost node costs a part an attempt rather than the part itself.
    test "the parts go round robin between the nodes that share them, this node first",
         %{parts: parts} do
      # The cluster lists this node last, and it still takes the first part: the
      # node that owns the run is the one that answers the page, so it is the one
      # whose work a reader can watch.
      here = entry("node2", self: true)
      peer = entry("node1")

      assert [{_, [first, first_backup]}, {_, [second, second_backup]}] =
               Partition.hosts(parts, [peer, here], ["monty"])

      assert first.self
      assert first_backup.name == "node1"
      assert second.name == "node1"
      assert second_backup.self
    end

    test "a node that cannot step what the run needs is not handed a part", %{parts: parts} do
      here = entry("node1", self: true, capabilities: ["monty", "world:mujoco"])
      laptop = entry("node2")

      assert [{_, [first]}, {_, [second]}] =
               Partition.hosts(parts, [here, laptop], ["monty", "world:mujoco"])

      assert first.self
      assert second.self
    end

    test "a node on another build is not handed a part", %{parts: parts} do
      # Handing a part over is calling into the peer's own code with this build's
      # record and reading this build's answer.
      here = entry("node1", self: true)
      older = entry("node2", version: "0.0.1")

      assert [{_, [first]}, {_, [second]}] = Partition.hosts(parts, [here, older], ["monty"])

      assert first.self
      assert second.self
    end

    test "a node speaking another protocol is not handed a part", %{parts: parts} do
      # The build says which record may travel; the protocol says what can be
      # asked of a node at all (`ExTbpMonty.Cluster.Protocol`). A peer that does
      # not speak it would fail half-way through the part instead of at the door.
      here = entry("node1", self: true)
      foreign = entry("node2", protocol: Protocol.version() + 1)

      assert [{_, [first]}, {_, [second]}] = Partition.hosts(parts, [here, foreign], ["monty"])

      assert first.self
      assert second.self
    end

    test "a node that is not alive is not a place a part goes", %{parts: parts} do
      here = entry("node1", self: true)
      gone = entry("node2", alive: false)

      assert [{_, [first]}, {_, [second]}] = Partition.hosts(parts, [here, gone], ["monty"])

      assert first.self
      assert second.self

      assert [{_, [primary]}] = Partition.hosts([hd(parts)], [here, gone], ["monty"])
      assert primary.self
    end

    test "three parts over two nodes go here, there, here", %{parts: two} do
      here = entry("node1", self: true)
      peer = entry("node2")
      third = %{index: 2, of: 3, phase: :eval, episodes: [2]}

      assert [{_, [first | _]}, {_, [second | _]}, {_, [last | _]}] =
               Partition.hosts(two ++ [third], [here, peer], ["monty"])

      assert {first.self, second.self, last.self} == {true, false, true}
    end
  end

  # A node as `ExTbpMonty.Cluster.Nodes.snapshot/0` describes it, cut down to what
  # the decision reads. This node's own entry is only ever built by `Partition`
  # itself, so a test cannot disagree with it about the directory or the build.
  defp entry(name, options \\ []) do
    %{
      node: String.to_atom("#{name}@127.0.0.1"),
      name: name,
      self: Keyword.get(options, :self, false),
      alive: Keyword.get(options, :alive, true),
      version: Keyword.get(options, :version, build()),
      protocol: Keyword.get(options, :protocol, Protocol.version()),
      capabilities: Keyword.get(options, :capabilities, ["monty"]),
      artifacts: Keyword.get(options, :artifacts, Monty.Studio.Artifacts.root())
    }
  end

  defp build, do: to_string(Application.spec(:ex_tbp_monty, :vsn))
end
