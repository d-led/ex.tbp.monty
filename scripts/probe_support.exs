# The setup a replay needs: Monty's recording, and the memory it was recorded with.
#
#   Code.require_file("probe_support.exs", __DIR__)
#   opened = ProbeSupport.setup(experiment)
#
# The fixtures in `test/fixtures/` were recorded with `constants.pretrained_dir`
# overridden to `pretrained_ycb_v10` (the command is in `docs/validation.md`).
# A config resolves `pretrained_dir` to Monty's own default today, which is
# `pretrained_ycb_v13` — a different memory, trained differently. Replaying v10
# percepts against v13 graphs would compare two experiments and call the
# difference a port's disagreement, so a probe names the release its recording
# came from instead of taking whatever the config resolves to.

defmodule ProbeSupport do
  @moduledoc "Replay setups that name the memory their recording was made with."

  @model "surf_agent_1lm_10distinctobj"
  @release "pretrained_ycb_v10"

  @doc "Opens an experiment, with `model_name_or_path` naming the recorded release."
  @spec setup(String.t()) :: Monty.Studio.opened()
  def setup(experiment) do
    {:ok, opened} = Monty.Studio.open(experiment)
    %{opened | setup: %{opened.setup | model_name_or_path: model_path()}}
  end

  @doc "Monty's own directory for the model, in the release the recordings used."
  @spec model_path() :: Path.t()
  def model_path do
    Path.join([
      Monty.Prerequisites.root_default("MONTY_MODELS"),
      @release,
      @model,
      "pretrained"
    ])
  end
end
