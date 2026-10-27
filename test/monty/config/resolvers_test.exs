defmodule Monty.Config.ResolversTest do
  use ExUnit.Case, async: true

  alias Monty.Config.{Composer, Resolvers, Source}

  @moduletag :monty_source

  defp env(variables), do: fn name -> Map.get(variables, name) end

  defp resolve(tree, variables \\ %{}, opts \\ []) do
    Resolvers.resolve(
      tree,
      Keyword.merge([env: env(variables), monty_root: "/monty"], opts)
    )
  end

  describe "references into the tree" do
    test "replace the whole string and keep the referenced type" do
      tree = %{"constants" => %{"min_eval_steps" => 5}, "steps" => "${constants.min_eval_steps}"}

      assert resolve(tree) == {:ok, %{"constants" => %{"min_eval_steps" => 5}, "steps" => 5}}
    end

    test "interpolate inside a larger string" do
      tree = %{"dir" => "/runs", "path" => "${dir}/episode_0"}

      assert resolve(tree) == {:ok, %{"dir" => "/runs", "path" => "/runs/episode_0"}}
    end

    test "resolve chains through other interpolations" do
      tree = %{
        "base" => "/runs",
        "dir" => "${base}/exp",
        "log" => "${dir}/log"
      }

      assert {:ok, resolved} = resolve(tree)
      assert resolved["log"] == "/runs/exp/log"
    end

    test "a reference to nothing is an error, not a string that says ${...}" do
      assert resolve(%{"x" => "${constants.nope}"}) ==
               {:error, {:unresolved_reference, "constants.nope"}}
    end
  end

  describe "oc.env" do
    test "reads the variable" do
      assert resolve(%{"data" => "${oc.env:MONTY_DATA}"}, %{"MONTY_DATA" => "/data"}) ==
               {:ok, %{"data" => "/data"}}
    end

    test "falls back to the default" do
      assert resolve(%{"data" => "${oc.env:MONTY_DATA,/tmp/data}"}) ==
               {:ok, %{"data" => "/tmp/data"}}
    end

    test "names the variable it could not find" do
      assert resolve(%{"data" => "${oc.env:MONTY_DATA}"}) ==
               {:error, {:missing_environment_variable, "MONTY_DATA"}}
    end

    test "resolves inside a path" do
      tree = %{"data_path" => "${path.expanduser:${oc.env:MONTY_DATA}/objects}"}

      assert resolve(tree, %{"MONTY_DATA" => "/data"}) ==
               {:ok, %{"data_path" => "/data/objects"}}
    end
  end

  describe "numpy resolvers" do
    test "np.array reads a list" do
      assert resolve(%{"hsv" => "${np.array:[2, 0.5, 0.5]}"}) ==
               {:ok, %{"hsv" => [2.0, 0.5, 0.5]}}
    end

    test "np.ones makes a vector of ones" do
      assert resolve(%{"pose_vectors" => "${np.ones:3}"}) ==
               {:ok, %{"pose_vectors" => [1.0, 1.0, 1.0]}}
    end

    test "np.list_eval evaluates arithmetic with pi" do
      assert resolve(%{"pose_vectors" => "${np.list_eval:[np.pi / 8, np.pi * 2, np.pi * 2]}"}) ==
               {:ok, %{"pose_vectors" => [:math.pi() / 8, :math.pi() * 2, :math.pi() * 2]}}
    end
  end

  describe "class references" do
    test "monty.class keeps the dotted path for the registry to resolve" do
      tree = %{
        "monty_class" =>
          "${monty.class:tbp.monty.frameworks.models.evidence_matching.model.MontyForEvidenceGraphMatching}"
      }

      assert resolve(tree) ==
               {:ok,
                %{
                  "monty_class" =>
                    "tbp.monty.frameworks.models.evidence_matching.model.MontyForEvidenceGraphMatching"
                }}
    end
  end

  describe "path resolvers" do
    test "path.expanduser expands the home directory" do
      assert {:ok, %{"dir" => dir}} = resolve(%{"dir" => "${path.expanduser:~/tbp}"})
      assert dir == Path.expand("~/tbp")
    end

    test "path.tests points inside the Monty checkout's tests directory" do
      assert resolve(%{"file" => "${path.tests:conf/snapshots/a.yaml}"}) ==
               {:ok, %{"file" => "/monty/tests/conf/snapshots/a.yaml"}}
    end
  end

  describe "a real Monty experiment" do
    test "resolves completely, including the values inside nested lists" do
      if File.dir?(Source.conf_dir()) do
        {:ok, composed} = Composer.compose("randrot_noise_10distinctobj_dist_agent")
        variables = Map.new(~w(MONTY_DATA MONTY_MODELS MONTY_LOGS), &{&1, "/data"})

        assert {:ok, resolved} = Resolvers.resolve(composed, env: env(variables))

        refute Resolvers.unresolved?(resolved)

        assert get_in(resolved, ["experiment", "config", "monty_config", "monty_class"]) ==
                 "tbp.monty.frameworks.models.evidence_matching.model.MontyForEvidenceGraphMatching"

        feature_weights =
          get_in(resolved, [
            "experiment",
            "config",
            "monty_config",
            "learning_modules",
            "learning_module_0",
            "feature_weights",
            "patch"
          ])

        assert feature_weights["hsv"] == [2.0, 0.5, 0.5]
        assert feature_weights["pose_vectors"] == [1.0, 1.0, 1.0]
      end
    end
  end
end
