defmodule Monty.Studio.YamlTest do
  @moduledoc """
  A config is read back, so what is printed has to parse back to it: YAML wins
  over JSON only when it is not also less exact.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Yaml

  @config %{
    "episodes" => "all",
    "num_parallel" => 16,
    "defaults" => [
      %{"environment" => "mujoco_ycb_surf_agent"},
      %{"monty" => "evidencegraph_exp1000_emin_t3"}
    ],
    "experiment" => %{
      "_target_" => "contrib.liveview_experiment.src.experiment_factory.monty",
      "config" => %{
        "do_eval" => true,
        "seed" => 42,
        "supervised_lm_ids" => [],
        "monty_args" => %{"min_eval_steps" => 20, "num_exploratory_steps" => 1000}
      }
    }
  }

  test "prints a config that parses back to the config it was given" do
    assert @config |> Yaml.render() |> YamlElixir.read_from_string!() == @config
  end

  test "puts a nested key one level in rather than on one line" do
    yaml = Yaml.render(@config)

    assert yaml =~ ~r/^experiment:$/m
    assert yaml =~ ~r/^ {2}_target_: contrib/m
    assert yaml =~ ~r/^ {4}seed: 42$/m
    assert yaml =~ ~r/^ {6}num_exploratory_steps: 1000$/m
  end

  test "writes a list of maps as one item per line, keys lined up under the dash" do
    yaml = Yaml.render(%{"parts" => [%{"index" => 0, "phase" => "eval"}]})

    assert yaml == """
           parts:
             - index: 0
               phase: eval\
           """
  end

  # A config is full of words YAML reads as something else — the string "on",
  # the string "42" — and of interpolations whose braces and colons are structure
  # to a parser. What a person reads has to be what Monty was asked for.
  test "quotes only what a YAML reader would misread" do
    yaml =
      Yaml.render(%{
        "name" => "mug",
        "on" => "on",
        "count" => "42",
        "path" => "${path.x}/y",
        "empty" => ""
      })

    assert yaml =~ ~r/^name: mug$/m
    assert yaml =~ ~r/^on: "on"$/m
    assert yaml =~ ~r/^count: "42"$/m
    assert yaml =~ ~r{^path: "\$\{path.x\}/y"$}m
    assert yaml =~ ~r/^empty: ""$/m
  end

  test "colours the keys and escapes what the config holds" do
    html = %{"name" => "<b>"} |> Yaml.highlight() |> elem(1) |> IO.iodata_to_binary()

    assert html =~ ~s(<span class="text-info">name</span>: )
    assert html =~ "&lt;b&gt;"
  end
end
