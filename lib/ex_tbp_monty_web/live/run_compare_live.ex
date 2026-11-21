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

  alias Monty.Studio.{Artifacts, Comparison, Duration, EvalStats, Parts, RunHistory}

  # The runs a reader can pick from. A page of the newest is enough to compare
  # two of them, and asking a node for its whole history to draw forty rows would
  # be a read nobody asked for.
  @offered 40

  # The rows whose numbers are durations, so they read as time and not as
  # microseconds.
  @durations ["Model time", "World time", "Episode time", "Wall clock"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       runs: RunHistory.list(limit: @offered),
       comparison: nil,
       refusal: nil,
       from_statistics: false,
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
  defp compared(%{"a" => a, "b" => b}) when a == b do
    %{
      comparison: nil,
      refusal:
        "That is the same run twice, so every difference would be nought. Pick the other run.",
      from_statistics: false,
      form: to_form(%{"a" => a, "b" => b}, as: :picked)
    }
  end

  defp compared(%{"a" => a, "b" => b}) do
    picked = to_form(%{"a" => a, "b" => b}, as: :picked)

    with {:ok, left} <- picked_side(a),
         {:ok, right} <- picked_side(b),
         {:ok, left, right, from_statistics} <- sides(left, right) do
      case Comparison.compare(left, right) do
        {:ok, comparison} ->
          %{comparison: comparison, refusal: nil, from_statistics: from_statistics, form: picked}

        {:error, {:different_experiments, one, other}} ->
          %{
            comparison: nil,
            refusal: two_experiments(one, other),
            from_statistics: false,
            form: picked
          }
      end
    else
      {:error, reason} -> Map.put(refused(reason), :form, picked)
    end
  end

  defp compared(params) do
    %{
      comparison: nil,
      refusal: nil,
      from_statistics: false,
      form: to_form(%{"a" => params["a"], "b" => params["b"]}, as: :picked)
    }
  end

  # -- a side ---------------------------------------------------------------
  #
  # A pick is a run's id, or a part of one: the run, the wave and the number the
  # division gave it, because a run that trains and then evaluates numbers both
  # waves from nought. One control carries both kinds, because a second select
  # asking "a part of which run" would be asking the first one's answer again.

  defp picked_side(chosen) when chosen in [nil, ""], do: {:error, :not_picked}

  defp picked_side(chosen) do
    with {:ok, pick} <- parse_pick(chosen),
         {:ok, run} <- fetch(pick.run) do
      side_of(pick, run)
    end
  end

  defp parse_pick(chosen) do
    case String.split(chosen, "|") do
      [run] ->
        {:ok, %{kind: :run, run: run}}

      [run, phase, index] ->
        case Integer.parse(index) do
          {number, ""} when number >= 0 ->
            {:ok, %{kind: :part, run: run, phase: phase, index: number}}

          _not_a_number ->
            {:error, :not_picked}
        end

      _not_a_pick ->
        {:error, :not_picked}
    end
  end

  defp fetch(id) do
    if RunHistory.exists?(id), do: {:ok, RunHistory.head(id)}, else: {:error, :not_here}
  end

  # What the comparison reads of a run: its identity, the inputs a lever changed,
  # the numbers its summary holds, the wall clock the record's own two instants
  # give (`Duration.of_run/1` reports the work, not the clock) and where its
  # statistics are — which is what a comparison alongside a part reads instead.
  defp side_of(%{kind: :run}, run) do
    {:ok,
     %{
       name: label_of(run),
       experiment: run.experiment,
       inputs: run.inputs || %{},
       summary: run.summary || %{},
       wall_us: wall_us(run),
       part?: false,
       dir: Artifacts.dir(run.id)
     }}
  end

  defp side_of(%{kind: :part} = pick, run) do
    case Parts.find(run, pick.phase, pick.index) do
      {:ok, part} ->
        {:ok,
         %{
           name: label_of(run) <> " · " <> part_name(part),
           experiment: run.experiment,
           inputs: Map.put(run.inputs || %{}, "part", part_name(part)),
           summary: %{},
           wall_us: part_wall_us(run, part),
           part?: true,
           dir: Artifacts.dir(part["stream"])
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A part has no summary — its numbers are the `eval_stats.csv` in its own
  # directory — so when either side is a part, both are read that way: the run's
  # merged file and a part's own are the same format, and one table drawn from one
  # file format is a table whose two columns mean the same thing.
  defp sides(left, right) do
    if left.part? or right.part? do
      with {:ok, a} <- from_statistics(left),
           {:ok, b} <- from_statistics(right) do
        {:ok, a, b, true}
      end
    else
      {:ok, left, right, false}
    end
  end

  # `dir/1` builds this path from a UUID — the run's own, or the id of the stream
  # that collected the part — so the question here is only whether this node has
  # it.
  # sobelow_skip ["Traversal.FileModule"]
  defp from_statistics(side) do
    if File.dir?(side.dir) do
      stats = EvalStats.read(side.dir, side.name)
      {:ok, Comparison.from_stats(side.name, side.experiment, side.inputs, stats, side.wall_us)}
    else
      {:error, :not_here}
    end
  end

  defp part_name(part), do: "part #{part["index"] + 1} of #{part["of"]} (#{part["phase"]})"

  # A part's wall clock is its own row's two instants. A run that trained and then
  # evaluated numbers both waves from nought, and the rows carry no wave, so the
  # clock is left unsaid rather than read off the other wave's row.
  defp part_wall_us(run, part) do
    with [_one_wave] <- run |> Parts.parts_of() |> Enum.map(& &1["phase"]) |> Enum.uniq(),
         %{started_at: %DateTime{} = from, finished_at: %DateTime{} = to} <-
           Enum.find(RunHistory.parts(run.id), &(&1.part == part["index"])) do
      DateTime.diff(to, from, :microsecond)
    else
      _unknown -> nil
    end
  end

  defp refused(:not_picked) do
    %{
      comparison: nil,
      refusal: "Pick two of these: a run, or a part of one.",
      from_statistics: false
    }
  end

  defp refused(:not_here) do
    %{
      comparison: nil,
      refusal:
        "One of those has no statistics to read here yet: a part writes its own " <>
          "eval_stats.csv when it finishes, and a part performed on another node keeps " <>
          "it on that node.",
      from_statistics: false
    }
  end

  defp refused(:not_planned) do
    %{
      comparison: nil,
      refusal:
        "That run was not divided into parts, so it has no part to compare. " <>
          "Pick the run itself.",
      from_statistics: false
    }
  end

  defp refused(:no_such_part) do
    %{
      comparison: nil,
      refusal: "That run has no such part. Pick one the division made.",
      from_statistics: false
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
            to guess what the two runs are. A divided run offers each of its parts
            besides itself: two parts side by side are this page's own answer to
            whether the division changed what the run found.
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
          :if={@comparison && @comparison.differences == [] && @comparison.unrecorded == []}
          id="compare-same"
          class="text-sm text-base-content/70"
        >
          No input either record keeps differs. The configuration a run stepped is
          not in the record, so a change to it does not show here.
        </p>

        <p :if={@comparison && @comparison.differences != []} id="compare-differences" class="text-sm">
          The inputs that differ:
          <span class="font-mono">{Enum.join(@comparison.differences, ", ")}</span>
        </p>

        <%!-- What each side's step numbers measured. A lever is a change to what
        a number means, so the side that chose one says what its `sensors` or its
        `receive` counts — two runs compared without that is a comparison of two
        different questions. --%>
        <div
          :if={@comparison && @comparison.shapes != []}
          id="compare-shape"
          class="space-y-1 text-sm"
        >
          <p :for={{name, sentences} <- @comparison.shapes} id={"compare-shape-#{name}"}>
            <span class="font-mono">{name}</span>
            <span class="text-base-content/60">{Enum.join(sentences, " ")}</span>
          </p>
        </div>

        <p
          :if={@comparison && @comparison.unrecorded != []}
          id="compare-unrecorded"
          class="text-sm text-base-content/70"
        >
          Recorded by one run only:
          <span class="font-mono">{Enum.join(@comparison.unrecorded, ", ")}</span>
          — the other was started before that input existed, so this is not a change
          anyone made.
        </p>

        <p :if={@from_statistics} id="compare-statistics" class="text-sm text-base-content/70">
          A part has no summary of its own, so both columns here are read from the runs'
          <span class="font-mono">eval_stats.csv</span>
          — the file Monty writes, one row an
          episode and module — and a conclusion is the episode's own exit.
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
    [{"—", ""} | Enum.flat_map(runs, &options_of/1)]
  end

  # A divided run offers its parts under itself: a part is a thing a column can
  # hold, and comparing two of them is how a reader sees that the division did not
  # change what the run found.
  defp options_of(run) do
    [{label_of(run), run.id} | part_options(run)]
  end

  defp part_options(run) do
    Enum.map(Parts.parts_of(run), fn part ->
      {label_of(run) <> " · " <> part_name(part), "#{run.id}|#{part["phase"]}|#{part["index"]}"}
    end)
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
