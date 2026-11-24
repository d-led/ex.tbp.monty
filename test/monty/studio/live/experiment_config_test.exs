defmodule Monty.Studio.Live.ExperimentConfigTest do
  @moduledoc """
  The live capture run's experiment: an object nobody taught, taught where it
  stands.

  Two things about this config are the point of it. The memory starts empty, so
  the object *is* novel and the training epochs are what build a graph for it;
  and the file lives beside the mirror rather than in it, because
  `mix monty.inputs` writes `priv/monty` and deletes every YAML there that Monty
  does not ship — a config kept in the mirror lasts until the next refresh.
  """

  use ExUnit.Case, async: true

  alias Monty.Config.{Composer, Source}

  @experiment "live/novel_object_unsupervised"

  describe "the object is new to the run" do
    test "the memory starts empty, so there is nothing to match it against" do
      assert config()["model_name_or_path"] == ""
    end

    # Training builds the graph; the evaluation phase is the first chance to
    # match against what the run itself learned, which is what makes the two
    # phases worth switching between while the object turns.
    test "it trains before it evaluates" do
      assert config()["n_train_epochs"] > 0
      assert config()["n_eval_epochs"] > 0
    end
  end

  describe "where the config lives" do
    test "the studio lists it among the experiments this tree carries" do
      assert @experiment in Source.experiments(Source.conf_dirs())
    end

    test "outside the mirror that the sync prunes" do
      assert File.exists?(path())
      assert inside?(path(), Source.extra_root())
      refute inside?(path(), Source.inputs_root())
    end
  end

  # `priv/monty` is a string prefix of `priv/monty_experiments`, so a string
  # test would say every config of ours sits in the mirror; the path a prune
  # walks is the directory, not the text. `Path.relative_to/2` answers with the
  # path unchanged when the two share no prefix, which is the "outside" case.
  defp inside?(path, root) do
    case Path.relative_to(Path.expand(path), Path.expand(root)) do
      "/" <> _absolute -> false
      ".." -> false
      _inside -> true
    end
  end

  defp config, do: get_in(composed(), ["experiment", "config"])

  defp composed do
    {:ok, tree} = Composer.compose(@experiment)

    tree
  end

  defp path do
    Path.join([Source.extra_root(), "sets/live/conf/experiment", @experiment <> ".yaml"])
  end
end
