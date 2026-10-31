defmodule ExTbpMonty.Mcp.Tools.Studio do
  @moduledoc """
  `monty_studio`: what this deployment is, and how many runs it can hold at once.
  """

  alias ExTbpMonty.Mcp.Studio

  @doc """
  Answers the questions that are about the deployment rather than about a config.
  """
  def about(_args, ctx) do
    studio = Studio.describe()

    {:ok,
     %{
       text: text(studio, ctx.base_url),
       structured: studio
     }}
  end

  # Numbers first, then the sentence that says what they mean: "can we run them
  # in parallel" is answered by the queue's limit, not by the config's
  # `num_parallel`, and the two are different questions.
  defp text(studio, base_url) do
    """
    #{studio.experiments} experiments preconfigured; #{runs_line(studio.runs)}

    #{parallel(studio.parallel)}
    #{studio.parallel.how}
    Monty does the same thing its own way: #{studio.parallel.monty_equivalent}.

    World: #{studio.world.mode} — #{studio.world.note}.

    Prerequisites: #{prerequisites_line(studio.prerequisites)}

    Runs: #{base_url}/runs · integrations: #{base_url}/mcp/config
    """
  end

  defp parallel(%{episodes_at_once: nil}), do: "Parallel: no queue is running here."

  defp parallel(parallel) do
    "Parallel: #{parallel.episodes_at_once} episode(s) at a time#{running(parallel)}."
  end

  defp running(%{running_now: nil, paused?: false}), do: ""
  defp running(%{running_now: nil, paused?: true}), do: " (queue paused)"
  defp running(%{running_now: count, paused?: true}), do: " (#{count} running, queue paused)"
  defp running(%{running_now: count}), do: " (#{count} running now)"

  defp runs_line(counts) when counts == %{}, do: "no runs yet"

  defp runs_line(counts) do
    parts =
      counts
      |> Enum.sort_by(fn {_state, count} -> -count end)
      |> Enum.map_join(" · ", fn {state, count} -> "#{count} #{state}" end)

    parts <> " run(s)"
  end

  defp prerequisites_line([]), do: "none configured"

  defp prerequisites_line(prerequisites) do
    present = Enum.count(prerequisites, & &1.present?)

    details =
      Enum.map_join(prerequisites, " · ", fn prerequisite ->
        "#{prerequisite.id} #{if prerequisite.present?, do: "present", else: "missing"}"
      end)

    "#{present}/#{length(prerequisites)} present (#{details})"
  end
end
