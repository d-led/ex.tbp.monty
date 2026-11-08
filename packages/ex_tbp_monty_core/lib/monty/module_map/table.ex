defmodule Monty.ModuleMap.Table do
  @moduledoc """
  The map as `/modules` reads it: one row per class, with the two files a reader
  wants to open and the one fact the map alone cannot show.

  Every row is the generated map (`Monty.ModuleMap.Data`) — the class, the
  Elixir module the rule gives it, and its status — so the page cannot drift
  from `mix monty.module_map.verify`. What is added here is only what follows
  from that data: the upstream file at the commit the map records, this
  repository's file for the module an implemented class lives in, and the
  stand-in the map carries for a class the runtime replaces.

  A row is filterable by *any word in it*: the text searched is every field
  joined, so `camera implemented`, `graph_matching planned` and `runtime` all
  find what a reader means without a column being named.
  """

  alias Monty.ModuleMap

  @upstream "https://github.com/thousandbrainsproject/"

  @typedoc """
  One class, as a row of the table.

  `elixir_url` is nil for a class this application has not written: there is no
  file to open, and the name is the contract for the file there will be.
  """
  @type row :: %{
          id: String.t(),
          package: String.t(),
          class: String.t(),
          file: String.t(),
          python_url: String.t() | nil,
          monty_test_url: String.t() | nil,
          elixir: String.t(),
          elixir_url: String.t() | nil,
          test_url: String.t() | nil,
          status: :implemented | :planned | :excluded,
          reason: String.t() | nil,
          stand_ins: [map()],
          text: String.t()
        }

  @doc """
  The rows, in the map's own order.

  Options: `:repo` — this repository's URL, which is what the "our file" links
  hang off — and `:revision`, the commit they point at (a release knows its own;
  a checkout that was never built links to `main`).
  """
  @spec rows(keyword()) :: [row()]
  def rows(opts \\ []) do
    repo = Keyword.get(opts, :repo)
    revision = Keyword.get(opts, :revision) || "main"
    commits = commits()

    for entry <- ModuleMap.load(),
        %{python: class} = cls <- entry.classes do
      stand_ins = Map.get(cls, :stand_in, [])

      fields = %{
        package: entry.package,
        class: class,
        file: entry.python,
        python_url: upstream_url(entry, Map.get(commits, entry.package)),
        monty_test_url: monty_test_url(entry, Map.get(commits, entry.package)),
        elixir: cls.elixir,
        elixir_url: file_url(repo, revision, cls),
        test_url: test_url(repo, revision, cls),
        status: cls.status,
        reason: Map.get(cls, :reason),
        stand_ins: with_links(stand_ins, repo, revision)
      }

      fields
      |> Map.put(:id, entry.package <> "#" <> entry.python <> "#" <> class)
      |> Map.put(:text, text_of(fields))
    end
  end

  # The commit each package was read from, so an upstream link cannot silently
  # follow a branch that has moved since the map was generated.
  defp commits do
    Map.new(ModuleMap.sources(), fn {package, source} -> {package, source["commit"]} end)
  end

  # Every word a reader might type, lower-cased: the class, both paths, both
  # modules, the status, the reason, and what stands in — with an Elixir module
  # also spelled the way it is written in a file, so `runtime model` finds
  # `Monty.Runtime.Model`.
  defp text_of(fields) do
    stand_in_words =
      Enum.flat_map(fields.stand_ins, fn stand_in ->
        [describe(stand_in), spoken(name_of(stand_in))]
      end)

    [
      fields.package,
      fields.class,
      fields.file,
      fields.elixir,
      spoken(fields.elixir),
      to_string(fields.status),
      fields.reason
      | stand_in_words
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  @doc """
  The rows matching a query and a status.

  `query` is any whitespace-separated words, each of which has to appear
  somewhere in the row; `status` is `:all` (or nil) or one of the map's
  statuses. Both are the page's URL state, so the same view can be linked to.
  """
  @spec filter([row()], String.t() | nil, atom() | nil) :: [row()]
  def filter(rows, query, status) do
    tokens = tokens(query)

    Enum.filter(rows, &(in_status?(&1, status) and matches?(&1, tokens)))
  end

  @doc "The statuses a row can have, in the order the page offers them."
  @spec statuses() :: [atom()]
  def statuses, do: [:implemented, :planned, :excluded]

  @doc """
  The status a page should filter by, from what the URL said.

  A query string is not trusted with an atom: an unknown word is no filter at
  all, which shows everything and cannot crash a page.
  """
  @spec status(String.t() | atom() | nil) :: atom()
  def status(nil), do: :all
  def status(:all), do: :all
  def status(status) when status in [:implemented, :planned, :excluded], do: status

  def status(name) when is_binary(name) do
    Enum.find(statuses(), :all, &(to_string(&1) == name))
  end

  def status(_unknown), do: :all

  defp tokens(nil), do: []
  defp tokens(query), do: query |> String.downcase() |> String.split(~r/\s+/, trim: true)

  defp in_status?(_row, status) when status in [nil, :all], do: true
  defp in_status?(row, status), do: row.status == status

  defp matches?(_row, []), do: true
  defp matches?(row, tokens), do: Enum.all?(tokens, &String.contains?(row.text, &1))

  # The upstream file at the commit the map was generated from. A package with
  # no recorded commit — a map generated before this was recorded — links to the
  # default branch rather than to nothing.
  defp upstream_url(entry, commit) do
    package = ModuleMap.package(entry.package)

    if package do
      commit = commit || "main"

      @upstream <>
        "tbp." <>
        package.name <> "/blob/" <> commit <> "/" <> package.relative <> "/" <> entry.python
    end
  end

  # Where our module's file is, by the rule the map itself keeps: the file the
  # generator recorded for a written class, and, for a class that is only named,
  # the path its name gives it (`Monty.A.B` is `lib/monty/a/b.ex`). The name is
  # the contract either way, so both columns are links and neither is a guess
  # about whether a file is there yet.
  defp file_url(nil, _revision, _cls), do: nil

  defp file_url(repo, revision, %{elixir: elixir} = cls) do
    path = Map.get(cls, :file) || "lib/" <> Macro.underscore(elixir) <> ".ex"

    repo <> "/blob/" <> revision <> "/" <> path
  end

  # Monty's own test for the file, where the package keeps its tests in the tree
  # that mirrors `src/tbp/monty` (`tests/unit/frameworks/models/
  # sensor_modules_test.py`). `conf/` is Hydra tooling that this application
  # replaces rather than ports, and it has no such test; `tbp.teleop` ships no
  # tests at all, so its rows offer none rather than a link to nothing.
  defp monty_test_url(%{package: "monty", python: python}, commit)
       when is_binary(python) do
    if String.starts_with?(python, "conf/") do
      nil
    else
      @upstream <>
        "tbp.monty/blob/" <> (commit || "main") <> "/tests/unit/" <> test_path(python)
    end
  end

  defp monty_test_url(_entry, _commit), do: nil

  defp test_path(python), do: String.replace_suffix(python, ".py", "_test.py")

  # Ours, where our tests mirror `lib/` the same way: a written module's test is
  # its own file with `_test.exs` after it. A class that is only named has no
  # module, so it has no test to point at.
  defp test_url(_repo, _revision, %{status: status}) when status != :implemented, do: nil
  defp test_url(nil, _revision, _cls), do: nil

  defp test_url(repo, revision, %{elixir: elixir}) do
    repo <> "/blob/" <> revision <> "/test/" <> Macro.underscore(elixir) <> "_test.exs"
  end

  # A stand-in wears a link where it has one: a module this application wrote
  # (it exists — `mix monty.module_map.verify` says so) or a carried file.
  defp with_links(stand_ins, repo, revision) do
    Enum.map(stand_ins, fn stand_in ->
      Map.put(stand_in, :url, stand_in_url(stand_in, repo, revision))
    end)
  end

  defp stand_in_url(_stand_in, nil, _revision), do: nil

  defp stand_in_url(%{kind: :module, file: file}, repo, revision),
    do: repo <> "/blob/" <> revision <> "/" <> file

  defp stand_in_url(%{kind: :module, name: module}, repo, revision) do
    repo <> "/blob/" <> revision <> "/lib/" <> Macro.underscore(module) <> ".ex"
  end

  defp stand_in_url(%{kind: :file, path: path}, repo, revision),
    do: repo <> "/blob/" <> revision <> "/" <> path

  defp stand_in_url(_stand_in, _repo, _revision), do: nil

  @doc "What a stand-in is called, as the table prints it."
  @spec describe(map()) :: String.t()
  def describe(%{kind: :module, name: module}), do: inspect(module)
  def describe(%{kind: :file, path: path}), do: path
  def describe(other), do: inspect(other)

  defp name_of(%{kind: :module, name: module}), do: inspect(module)
  defp name_of(%{kind: :file, path: path}), do: path
  defp name_of(_other), do: nil

  defp spoken(nil), do: nil
  defp spoken(name), do: String.replace(name, [".", "/", "_"], " ")
end
