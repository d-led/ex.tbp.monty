defmodule Monty.Studio.Readiness do
  @moduledoc """
  Which of Monty's experiments this application can run, and what stands in the
  way of the rest.

  "Sixty of two hundred and ten" is not the useful number on its own: an
  experiment is refused because of a class this port has not written, or because
  its world is one this build does not carry, and those two are different work.
  This turns a set of opened setups into the answer a person planning the port
  needs — how many experiments each missing class would unblock **on its own**,
  and how many name it at all.

  Pure where it matters: `classify/1` reads one outcome and `summarise/1` counts
  a list of them, so both can be tested on a fixture. `catalog/1` is the impure
  edge — it opens every experiment and keeps the answer — and
  [`mix monty.readiness`](`Mix.Tasks.Monty.Readiness`) and the experiments page
  both read it, so the page and the count cannot disagree.
  """

  alias Monty.Studio
  alias Monty.Studio.{Catalog, Finding, Memory, Setup}

  @typedoc """
  One experiment's answer.

  `:runnable` is what every entry point already honours — the setup has no
  `:error` finding. `:did_not_compose` is a config this application cannot read
  at all, which is a finding about the port rather than about Monty.

  `:blocked_by` is the classes a run is refused on: the ones `Setup.blocking/1`
  calls `:unwritten` — no module here and nothing standing in for one — and the
  class of a learning module that refuses a config it cannot build, which is a
  written class with a gap in it rather than a missing one.
  """
  @type entry :: %{
          name: String.t(),
          status: :runnable | :refused | :did_not_compose,
          codes: [atom()],
          blocked_by: [String.t()]
        }

  @typedoc """
  One class, and the experiments it stands in front of.

  `experiments` are the ones it blocks **alone** — nothing else is wrong with
  them — so writing it and nothing else makes exactly those run. `naming` counts
  every refused experiment that names it.
  """
  @type ranking :: %{
          class: String.t(),
          alone: non_neg_integer(),
          naming: non_neg_integer(),
          experiments: [String.t()]
        }

  @type survey :: %{
          entries: [entry()],
          runnable: non_neg_integer(),
          refused: non_neg_integer(),
          did_not_compose: non_neg_integer(),
          by_code: [%{code: atom(), count: non_neg_integer()}],
          by_class: [ranking()]
        }

  @doc """
  One experiment's outcome, as `Monty.Studio.open/2` answers them.
  """
  @spec classify({String.t(), {:ok, Setup.t()} | {:error, term()}}) :: entry()
  def classify({name, {:ok, %Setup{} = setup}}) do
    errors = Finding.at(setup.findings, :error)

    %{
      name: name,
      status: if(errors == [], do: :runnable, else: :refused),
      codes: errors |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort(),
      blocked_by: blocked_by(setup, errors)
    }
  end

  def classify({name, {:error, _reason}}) do
    %{name: name, status: :did_not_compose, codes: [:does_not_compose], blocked_by: []}
  end

  defp blocked_by(setup, errors) do
    unwritten = for module <- Setup.blocking(setup).unwritten, do: module.class

    (unwritten ++ unbuildable_classes(errors))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A learning module the map calls written but which refuses this config names
  # its own class in the finding's `where`: that class is the work, and it is a
  # gap to close rather than a module to write.
  defp unbuildable_classes(errors) do
    for %{code: :learning_module_not_buildable, where: where} <- errors,
        is_binary(where),
        [_, class] <- [Regex.run(~r/([A-Za-z0-9_]+)\}?$/, where)],
        do: class
  end

  @doc """
  One experiment, opened and read.

  `opts` are `Monty.Studio.open/2`'s — `:conf_dir` and `:world_simulator`.
  """
  @spec classified(String.t(), keyword()) :: entry()
  def classified(name, opts \\ []) do
    case Studio.open(name, opts) do
      {:ok, %{setup: setup}} -> classify({name, {:ok, setup}})
      {:error, reason} -> classify({name, {:error, reason}})
    end
  end

  @doc """
  Every catalogue experiment's answer, from a cache.

  Reading what a config *means* is composing it, and composing all of Monty's
  costs about a second and a half — more than a page mount can pay on every
  visit. So the answer is kept until something it was computed from moves: the
  catalogue itself (`Catalog.stamp/1`), the world a setup is read for, or the
  libraries on this machine (an experiment refused for want of a pretrained
  memory stops being refused the moment one is exported).

  `opts` are `Monty.Studio.open/2`'s: `:conf_dir` and `:world_simulator`.
  """
  @spec catalog(keyword()) :: survey()
  def catalog(opts \\ []) do
    key = {__MODULE__, :catalog, Catalog.stamp(opts), world(opts), libraries_stamp()}

    case :persistent_term.get(key, nil) do
      nil ->
        survey = opts |> read_catalog() |> summarise()
        :persistent_term.put(key, survey)
        survey

      survey ->
        survey
    end
  end

  @doc """
  What the experiments page filters on, per experiment: `"yes"` when nothing
  here refuses it, `"no"` when something does.
  """
  @spec verdicts(survey()) :: %{String.t() => String.t()}
  def verdicts(%{entries: entries}) do
    Map.new(entries, fn entry ->
      {entry.name, if(entry.status == :runnable, do: "yes", else: "no")}
    end)
  end

  @doc """
  Forgets every cached answer.

  A test that changes the world (or the libraries directory) under the cache has
  to say so; nothing in production changes either without the key moving.
  """
  @spec forget() :: :ok
  def forget do
    for {{__MODULE__, :catalog, _stamp, _world, _libraries} = key, _value} <-
          :persistent_term.get(),
        do: :persistent_term.erase(key)

    :ok
  end

  defp read_catalog(opts) do
    open = Keyword.take(opts, [:conf_dir, :world_simulator])

    for experiment <- Catalog.experiments(Keyword.take(opts, [:conf_dir])),
        do: classified(experiment.name, open)
  end

  # What the answer depends on besides the catalogue: which world a setup is read
  # for, and which libraries are on this machine. The library listing is two
  # levels of `ls` — the release directories and the files in them — so a file
  # exported into a release that already exists moves the key too.
  defp world(opts),
    do:
      Keyword.get(opts, :world_simulator) || Application.get_env(:ex_tbp_monty, :world_simulator)

  defp libraries_stamp do
    dir = Memory.libraries_dir()

    case File.ls(dir) do
      {:ok, releases} -> {dir, Map.new(releases, &{&1, files_in(Path.join(dir, &1))})}
      _missing -> {dir, :none}
    end
  end

  defp files_in(dir) do
    case File.ls(dir) do
      {:ok, files} -> Enum.sort(files)
      _missing -> []
    end
  end

  @doc """
  The counts, and the classes ranked by the experiments they alone stand in front
  of.
  """
  @spec summarise([entry()]) :: survey()
  def summarise(entries) do
    %{
      entries: entries,
      runnable: count(entries, :runnable),
      refused: count(entries, :refused),
      did_not_compose: count(entries, :did_not_compose),
      by_code: tally(Enum.flat_map(entries, & &1.codes)),
      by_class: ranking(Enum.filter(entries, &(&1.status == :refused)))
    }
  end

  defp count(entries, status), do: Enum.count(entries, &(&1.status == status))

  defp tally(codes) do
    codes
    |> Enum.frequencies()
    |> Enum.sort_by(fn {code, count} -> {-count, code} end)
    |> Enum.map(fn {code, count} -> %{code: code, count: count} end)
  end

  # A class that one experiment names and another does not is still the same
  # class: the answer is per class, not per (class, experiment) pair.
  defp ranking(refused) do
    refused
    |> Enum.flat_map(& &1.blocked_by)
    |> Enum.uniq()
    |> Enum.map(fn class ->
      naming = Enum.filter(refused, &(class in &1.blocked_by))
      alone = Enum.filter(naming, &blocks_alone?(&1, class))

      %{
        class: class,
        alone: length(alone),
        naming: length(naming),
        experiments: alone |> Enum.map(& &1.name) |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{-&1.alone, -&1.naming, &1.class})
  end

  # "Alone" is a statement about the whole experiment: the only thing wrong with
  # it is the class, so nothing but that class has to be written.
  defp blocks_alone?(entry, class) do
    entry.blocked_by == [class] and
      entry.codes in [[:modules_not_ported], [:learning_module_not_buildable]]
  end
end
