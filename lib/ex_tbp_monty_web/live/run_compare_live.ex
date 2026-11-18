defmodule ExTbpMontyWeb.RunCompareLive do
  @moduledoc """
  Two runs of one experiment, put beside each other.

  The page can start the same experiment twice with one input apart — the sensor
  round, the scheduling of a step — and this is where the two are read together:
  each run's own numbers, one column a run, and the inputs that differ named
  above the table. Two different experiments are refused, because their numbers
  differ for a reason that is not a lever (`Monty.Studio.Comparison`).
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Studio.{Comparison, Duration, RunHistory}

  # The runs a reader can pick from. A page of the newest is enough to compare
  # two of them, and asking a node for its whole history to draw forty rows would
  # be a read nobody asked for.
  @offered 40

  # The rows whose numbers are durations, so they read as time and not as
  # microseconds.
  @durations ["Model time", "World time", "Wall clock"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       runs: RunHistory.list(limit: @offered),
       comparison: nil,
       refusal: nil,
       form: to_form(%{"a" => nil, "b" => nil}, as: :picked)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, compared(params))}
  end

  @impl true
  def handle_event("choose", %{"picked" => params}, socket) do
    query =
      %{"a" => params["a"], "b" => params["b"]}
      |> Enum.reject(fn {_side, id} -> id in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/compare?#{query}")}
  end

  # Two runs asked for: either the comparison, or the sentence saying why the two
  # cannot be compared.
  defp compared(%{"a" => a, "b" => b}) do
    picked = to_form(%{"a" => a, "b" => b}, as: :picked)

    with {:ok, left} <- fetch(a),
         {:ok, right} <- fetch(b) do
      case Comparison.compare(side(left), side(right)) do
        {:ok, comparison} ->
          %{comparison: comparison, refusal: nil, form: picked}

        {:error, {:different_experiments, one, other}} ->
          %{comparison: nil, refusal: two_experiments(one, other), form: picked}
      end
    else
      _not_here ->
        %{
          comparison: nil,
          refusal:
            "One of those runs is not on this node, so there is nothing to put beside the other.",
          form: picked
        }
    end
  end

  defp compared(params) do
    %{
      comparison: nil,
      refusal: nil,
      form: to_form(%{"a" => params["a"], "b" => params["b"]}, as: :picked)
    }
  end

  defp fetch(id) do
    if RunHistory.exists?(id), do: {:ok, RunHistory.head(id)}, else: :not_here
  end

  # What the comparison reads of a run: its identity, the inputs a lever changed,
  # the numbers its summary holds, and the wall clock the record's own two
  # instants give (`Duration.of_run/1` reports the work, not the clock).
  defp side(run) do
    %{
      name: label_of(run),
      experiment: run.experiment,
      inputs: run.inputs || %{},
      summary: run.summary || %{},
      wall_us: wall_us(run)
    }
  end

  defp wall_us(%{started_at: %DateTime{} = from, finished_at: %DateTime{} = to}),
    do: DateTime.diff(to, from, :microsecond)

  defp wall_us(_not_finished), do: nil

  defp two_experiments(one, other) do
    "These are two different experiments (#{one} and #{other}), so their numbers " <>
      "differ for a reason that is not a lever. Compare two runs of one experiment."
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="compare" class="space-y-6 py-2">
        <header class="space-y-1">
          <h1 class="text-lg font-semibold">Two runs, side by side</h1>
          <p class="text-sm text-base-content/70">
            Start one experiment twice with one input changed, then pick both here.
            The inputs that differ are named above the numbers, so a reader never has
            to guess what the two runs are.
          </p>
        </header>

        <.form
          for={@form}
          id="compare-form"
          phx-change="choose"
          class="flex flex-wrap items-end gap-3"
        >
          <.input
            field={@form[:a]}
            label="First run"
            type="select"
            options={run_options(@runs)}
          />
          <.input
            field={@form[:b]}
            label="Second run"
            type="select"
            options={run_options(@runs)}
          />
        </.form>

        <p :if={@refusal} id="compare-refusal" class="text-sm text-warning">{@refusal}</p>

        <p
          :if={@comparison && @comparison.differences == []}
          id="compare-same"
          class="text-sm text-base-content/70"
        >
          No input differs between these two runs, so their numbers are the same
          experiment twice.
        </p>

        <p :if={@comparison && @comparison.differences != []} id="compare-differences" class="text-sm">
          The inputs that differ:
          <span class="font-mono">{Enum.join(@comparison.differences, ", ")}</span>
        </p>

        <table :if={@comparison} id="compare-table" class="w-full text-sm">
          <thead>
            <tr class="text-left text-base-content/60">
              <th class="py-1 font-medium"></th>
              <th :for={side <- @comparison.sides} class="py-1 font-medium">{side}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @comparison.rows}
              id={"compare-#{slug(row.label)}"}
              class="border-t border-base-300"
            >
              <th class="py-1 text-left font-normal text-base-content/70">{row.label}</th>
              <td class="py-1 font-mono">{text(row.label, row.a)}</td>
              <td class="py-1 font-mono">{text(row.label, row.b)}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end

  defp run_options(runs) do
    [{"—", ""} | Enum.map(runs, &{label_of(&1), &1.id})]
  end

  # The column's name, and the run's state when it is not finished: a summary is
  # written when a run settles, so an unfinished run's column would otherwise read
  # as its final numbers with no word saying they are not.
  defp label_of(run) do
    status = if run.status == "finished", do: "", else: " · #{run.status}"
    "#{run.experiment} · #{String.slice(run.id, 0, 8)}#{status}"
  end

  defp text(label, value) when label in @durations, do: Duration.humanize(value)
  defp text(_label, nil), do: "—"
  defp text(_label, value), do: to_string(value)

  defp slug(label) do
    label |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
  end
end
