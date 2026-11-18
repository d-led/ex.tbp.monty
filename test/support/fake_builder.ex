defmodule Monty.Test.FakeBuilder do
  @moduledoc """
  A builder that says which step it is on, so the states a build runs through can
  be tested without the geometry.

  The saga names the builder rather than calling it
  (`Monty.Prerequisites.Saga` `:builder` option), which is what lets a test drive
  `:building` the way `Monty.Test.FakeFetcher` drives a download.

  Configure through the application environment:

      config :ex_tbp_monty, fake_build_steps: ["first", "second"]

  A step named `"refuse"` makes the build refuse, so the failing path is a step
  rather than a second fake module. A step named `"wait"` never finishes, which
  is how a test holds a build in flight — minutes of work — while it cancels it.

  `config :ex_tbp_monty, fake_build_report_to: pid` names a process to tell the
  build's own pid, so a test watches the work stop instead of asking after it.
  """

  @doc """
  Runs the build `name` names, reporting each step as it starts.
  """
  @spec run(String.t(), (map() -> any())) :: {:ok, [String.t()]} | {:error, String.t()}
  def run(name, notify) do
    report_self()

    steps = Application.get_env(:ex_tbp_monty, :fake_build_steps, ["first", "second"])
    total = length(steps)

    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step, index}, {:ok, said} ->
      notify.(%{index: index, total: total, what: step})

      if step == "wait", do: Process.sleep(:infinity)

      if step == "refuse" do
        {:halt, {:error, "#{name} refused at #{step}"}}
      else
        {:cont, {:ok, said ++ ["#{name}/#{step}"]}}
      end
    end)
  end

  defp report_self do
    case Application.get_env(:ex_tbp_monty, :fake_build_report_to) do
      pid when is_pid(pid) -> send(pid, {:fake_builder, self()})
      _none -> :ok
    end
  end
end
