defmodule Monty.Prerequisites.BuildTest do
  @moduledoc """
  The inputs this application makes, driven the way `/prerequisites` drives
  them.

  The point of each case is the same question the page asks: after one click, is
  there a memory and an object set at the path the configs already name? The
  geometry is `ex_monty_cad`'s, from Hex, so a checkout with `mix deps.get` can
  answer it.
  """

  use ExUnit.Case, async: false

  alias Monty.Prerequisites
  alias Monty.Prerequisites.Build
  alias Monty.Test.PrerequisiteRoots

  setup do
    root = Path.join(System.tmp_dir!(), "build-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.delete_env(:ex_tbp_monty, :glb_getter)
    end)

    {:ok, root: root}
  end

  describe "a name this application cannot build" do
    test "is refused with a sentence rather than a silent nothing" do
      assert {:error, message} = Build.run("something_nobody_wrote", fn _ -> :ok end)
      assert message =~ "something_nobody_wrote"
    end
  end

  describe "the CAD parts" do
    @describetag timeout: 300_000

    test "are taught and meshed, one memory and one object set per recognition run", %{
      root: root
    } do
      PrerequisiteRoots.with_roots(root, fn ->
        steps = self()

        assert {:ok, said} = Build.run("cad_part_memories", &send(steps, {:step, &1}))

        # One line per memory: the run a person can make afterwards is one per
        # memory, so the count is what the build promised.
        assert length(said) == length(experiments())
        assert_received_step(:first)

        libraries = Prerequisites.root_path("MONTY_LIBRARIES")
        objects = Path.join(Prerequisites.root_path("MONTY_DATA"), "cad_objects")

        for experiment <- experiments() do
          {plan, setup} = plan_of(experiment)

          assert File.exists?(plan.memory),
                 "#{experiment} loads #{plan.memory}, which the build did not write"

          # Every object the run steps, not only the first: a memory of a part's
          # features answers four names, and a run is only able to ask about the
          # ones that were written as directories.
          for object <- Monty.Studio.Setup.objects(setup) do
            assert File.dir?(Path.join(objects, object)),
                   "#{experiment} steps #{object}, which the build did not write"
          end
        end

        assert File.dir?(libraries)
      end)
    end
  end

  describe "a corpus" do
    test "that cannot be fetched says which object refused, and writes no object set", %{
      root: root
    } do
      PrerequisiteRoots.with_roots(root, fn ->
        Application.put_env(:ex_tbp_monty, :glb_getter, fn _url, _opts ->
          {:error, :timeout}
        end)

        assert {:error, message} = Build.run("objaverse_dogs", fn _ -> :ok end)
        assert message =~ "failed"

        into = Path.join(Prerequisites.root_path("MONTY_DATA"), "mujoco/objects/objaverse_dogs")
        refute File.exists?(into)
      end)
    end

    test "whose files are all here is imported without touching the network", %{root: root} do
      PrerequisiteRoots.with_roots(root, fn ->
        Application.put_env(:ex_tbp_monty, :glb_getter, fn url, _opts ->
          flunk("a cached corpus is not fetched again, and this asked for #{url}")
        end)

        cache = Path.join(Prerequisites.root_path("MONTY_DATA"), "downloads/objaverse_dogs")
        File.mkdir_p!(cache)

        # Every uid the manifest names, cached — and what the import makes of a
        # file that is not a GLB is its own refusal, which is what this asserts:
        # the fetch step is skipped, the import step is reached, and the build
        # reports the refusal instead of pretending it wrote an object set.
        uids = manifest_uids()

        for uid <- uids, do: File.write!(Path.join(cache, uid <> ".glb"), "not a glb")

        assert {:error, message} = Build.run("objaverse_dogs", fn _ -> :ok end)
        assert message =~ "could not import"
      end)
    end
  end

  # The CAD set's own experiment configs, which is what a build reads: a name is
  # a config file, and the part it steps is in its env interface.
  defp experiments do
    Path.wildcard(
      Path.join([
        :code.priv_dir(:ex_tbp_monty),
        "monty_experiments/sets/cad/conf/experiment/cad/*.yaml"
      ])
    )
    |> Enum.map(&"cad/#{Path.basename(&1, ".yaml")}")
    |> Enum.sort()
  end

  defp plan_of(experiment) do
    {:ok, opened} = Monty.Studio.open(experiment, conf_dir: Monty.Config.Source.conf_dirs())
    {:ok, plan} = Monty.Studio.Cad.Preparation.plan(opened.setup)
    {plan, opened.setup}
  end

  defp manifest_uids do
    manifest =
      Path.join([
        :code.priv_dir(:ex_tbp_monty),
        "monty_experiments/sets/dogs/objaverse_dogs.json"
      ])

    manifest
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("objects")
    |> Enum.map(& &1["uid"])
  end

  defp assert_received_step(:first) do
    assert_receive {:step, %{index: 1, total: total, what: what}}
    assert total > 0
    assert is_binary(what) and what != ""
  end
end
