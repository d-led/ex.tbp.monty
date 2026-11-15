# Does our percept filter decide the way Monty's did, on his own percepts?
#
#   MIX_ENV=test mix run --no-start scripts/probe_read_rate.exs [experiment]
#
# Monty's recording carries, for every step his learning module was given a
# percept, the verdict his own `FeatureChangeFilter` reached: `pass_message` and
# `process_features_in_lm`. A percept that carries features is a read — the module
# keeps it and matches against it — and one that does not is a location-only step,
# where the hypotheses move and nothing is matched. That verdict is what decides
# the cost of an episode, so it is compared here without a world: his percepts, in
# his order, through our filter and the experiment's own thresholds.

defmodule ReadRate do
  @moduledoc false

  alias Monty.Frameworks.Models.SensorModules.FeatureChangeFilter
  alias Monty.Studio

  @fixture "test/fixtures/monty_base_10simobj_episode.jsonl"

  def main do
    experiment = System.argv() |> List.first() || "base_10simobj_surf_agent"

    {:ok, opened} = Monty.Studio.open(experiment)
    config = Enum.find(opened.setup.sensors, &(&1.id == "patch")).config
    {filter, memory} = FeatureChangeFilter.new(config["delta_thresholds"])

    {verdicts, _memory} =
      Path.expand(@fixture, Path.join(__DIR__, ".."))
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.reduce({[], memory}, fn step, {verdicts, memory} ->
        case step["learning_modules"]["learning_module_0"]["inputs"] do
          [] ->
            {verdicts, memory}

          [percept | _rest] ->
            his = percept["process_features_in_lm"]
            {ours, memory} = FeatureChangeFilter.call(filter, message(percept), memory)
            {[{step["episode_step"], his, ours.process_features_in_lm} | verdicts], memory}
        end
      end)

    disagreeing = verdicts |> Enum.reverse() |> Enum.reject(fn {_step, his, ours} -> his == ours end)

    verdicts
    |> Enum.reverse()
    |> Enum.reject(fn {_step, his, _ours} -> his end)
    |> Enum.take(0)

    IO.puts("#{length(verdicts)} percepts he passed, #{length(disagreeing)} decided differently")

    for {step, his, ours} <- Enum.take(disagreeing, 10) do
      IO.puts("  step #{step}: he said #{his}, we say #{ours}")
    end

    if disagreeing == [], do: IO.puts("\nthe filter agrees with his, percept by percept")
  end

  # His percept as the message the filter reads: the features it compares are the
  # non-morphological ones plus the pose vectors, and `on_object` sits among the
  # morphological ones.
  defp message(percept) do
    %Monty.Cmp.Message{
      sender_id: percept["sender_id"],
      sender_type: String.to_atom(percept["sender_type"]),
      location: percept["location"],
      confidence: percept["confidence"],
      pass_message: percept["pass_message"],
      process_features_in_lm: percept["process_features_in_lm"],
      morphological_features: percept["morphological_features"],
      non_morphological_features: percept["non_morphological_features"]
    }
  end
end

ReadRate.main()
