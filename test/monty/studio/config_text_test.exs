defmodule Monty.Studio.ConfigTextTest do
  use ExUnit.Case, async: true

  alias Monty.Config.Source
  alias Monty.Studio.ConfigText

  describe "what is written" do
    test "the config lands at the root, so its body is the experiment" do
      text = ConfigText.render(defaults: [{"monty", "one"}], experiment: %{"_target_" => "X"})

      assert text =~ ~r/^# @package _global_$/m
      assert {:ok, config} = Source.load_text(text)
      assert config.package == []
    end

    test "defaults keep their order, because composition order is meaning" do
      text =
        ConfigText.render(
          defaults: [{"/monty", "b"}, {"/environment", "a"}],
          experiment: %{}
        )

      assert {:ok, config} = Source.load_text(text)
      assert [{:group, "/monty", "b", nil}, {:group, "/environment", "a", nil}] = config.defaults
    end

    test "an interpolation is quoted, so the colons and brackets survive" do
      text =
        ConfigText.render(
          defaults: [],
          experiment: %{"config" => %{"model_name_or_path" => "${constants.dir}/model/"}}
        )

      assert text =~ ~s|"${constants.dir}/model/"|
      assert {:ok, config} = Source.load_text(text)

      assert config.body["experiment"]["config"]["model_name_or_path"] ==
               "${constants.dir}/model/"
    end

    test "an empty list, a number, a boolean and nil all read back as themselves" do
      text =
        ConfigText.render(
          defaults: [],
          experiment: %{
            "config" => %{
              "supervised_lm_ids" => [],
              "seed" => 7,
              "do_eval" => true,
              "model_name_or_path" => nil
            }
          }
        )

      assert {:ok, config} = Source.load_text(text)
      values = config.body["experiment"]["config"]

      assert values["supervised_lm_ids"] == []
      assert values["seed"] == 7
      assert values["do_eval"] == true
      assert values["model_name_or_path"] in [nil, ""]
    end

    test "nested maps keep their nesting" do
      text =
        ConfigText.render(
          defaults: [],
          experiment: %{"config" => %{"logging" => %{"run_name" => "mine"}}}
        )

      assert {:ok, config} = Source.load_text(text)
      assert config.body["experiment"]["config"]["logging"] == %{"run_name" => "mine"}
    end
  end
end
