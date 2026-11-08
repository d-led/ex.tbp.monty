defmodule Monty.Studio.Settings do
  @moduledoc """
  The studio's knobs: values that can be changed while the application runs.

  Two kinds of number look alike on this project and are not the same. A *boot*
  value — the database pool's timeout, the port a run's world is dialled on — is
  read once, when the application starts, and changing it means restarting it;
  `Monty.Studio.System` shows those and says so. A *setting* is read per use, so
  changing it takes effect on the next page, and this module is where they live.

  Each setting declares its default, its accepted range and the sentence that
  says what it does, and a value that is not stored is not missing: the default
  is what the application does, and the table says only where somebody disagreed
  with it. That is what lets a new setting be added without a data migration.

  The table is `studio_settings` — a key, a value as text, and when it was last
  written. Values are kept as text because that is what a form sends; parsing and
  range checking happen here, so a page cannot store a number the application
  would then have to defend against.
  """

  import Ecto.Query

  alias ExTbpMonty.Repo

  @settings [
    %{
      key: "run_refresh_ms",
      label: "Run page update window",
      unit: "ms",
      default: 250,
      range: 50..10_000,
      help:
        "How long a burst of run events is coalesced before the page reads the " <>
          "record again. It is not a poll: the page is woken by the run, and this " <>
          "is how long it waits for the rest of a burst instead of reading once per step."
    },
    %{
      key: "db_write_timeout_ms",
      label: "Episode write timeout",
      unit: "ms",
      default: 120_000,
      range: 1_000..600_000,
      help:
        "How long the episode-boundary write may take before the database pool " <>
          "gives up on it. It is passed per statement, so this one takes effect " <>
          "without a restart — unlike the pool's own settings, which do not."
    },
    %{
      key: "run_stale_after_s",
      label: "A run is not progressing after",
      unit: "s",
      default: 60,
      range: 10..3_600,
      help:
        "How quiet a running record has to be before its page says it is not " <>
          "progressing. It is a claim about somebody else's process, so it has to " <>
          "be longer than the slowest step a run may take."
    },
    %{
      key: "job_abandon_after_s",
      label: "A run is abandoned after",
      unit: "s",
      default: 60,
      range: 10..3_600,
      help:
        "How quiet a record has to be before the reaper decides nobody is " <>
          "working on it and marks it abandoned. This is the one that ends a run, " <>
          "so it must not be shorter than the staleness above."
    }
  ]

  @type row :: %{
          key: String.t(),
          label: String.t(),
          unit: String.t(),
          default: integer(),
          range: Range.t(),
          help: String.t()
        }

  @doc "Every setting this application has, in the order a page should show them."
  @spec known() :: [row()]
  def known, do: @settings

  @doc """
  What a setting is set to now, or its default when nobody has said otherwise.

  A key that is not a setting is a programming error rather than a lookup that
  quietly answers nil: a page reading `Settings.get("run-refresh-ms")` would
  otherwise show a default forever and never say why.
  """
  @spec get(String.t()) :: integer()
  def get(key) when is_binary(key) do
    row = row!(key)

    # Read on every render and every tick of a live run, so it is cached: a
    # setting that cost a database query would make the page it is meant to make
    # responsive the slowest thing in the studio. `put/2` refreshes the cache.
    case :persistent_term.get({__MODULE__, key}, :unset) do
      :unset ->
        value = read(row)
        :persistent_term.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end

  @doc "Every setting, with what it is set to now."
  @spec values() :: %{String.t() => integer()}
  def values, do: Map.new(@settings, &{&1.key, get(&1.key)})

  @doc """
  Stores a value, or says why it will not.

  The answer is `{:ok, value}` with what was stored, or `{:error, message}` with
  the sentence a page can show: a range is what the application can live with,
  and refusing out of range here is kinder than a chart that redraws a thousand
  times a second because somebody typed `1`.
  """
  @spec put(String.t(), term()) :: {:ok, integer()} | {:error, String.t()}
  def put(key, value) when is_binary(key) do
    row = row!(key)

    with {:ok, parsed} <- parse(row, value),
         :ok <- in_range(row, parsed) do
      upsert(row, parsed)
      {:ok, parsed}
    end
  end

  @doc """
  The settings, ready for a form: values as the text the browser sends back.

  Text rather than integers because a form field that hands back "250" and is
  given 250 compares unequal to itself on the next validation, which is how a
  form starts red before anybody has touched it.
  """
  @spec form_values() :: %{String.t() => String.t()}
  def form_values, do: Map.new(@settings, &{&1.key, Integer.to_string(get(&1.key))})

  defp row!(key) do
    case Enum.find(@settings, &(&1.key == key)) do
      nil -> raise ArgumentError, "#{inspect(key)} is not a studio setting"
      row -> row
    end
  end

  defp in_range(%{range: range, label: label}, value) do
    if value in range,
      do: :ok,
      else: {:error, "#{label} has to be between #{range.first} and #{range.last}"}
  end

  defp parse(%{label: _label}, value) when is_integer(value), do: {:ok, value}

  defp parse(%{label: label}, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _not_a_number -> {:error, "#{label} has to be a whole number"}
    end
  end

  defp parse(%{label: label}, _value), do: {:error, "#{label} has to be a whole number"}

  defp parse!(row, value) do
    case parse(row, value) do
      {:ok, number} -> number
      # A stored value is only unparseable if somebody wrote it by hand; the
      # default keeps the application running and the page says what it is.
      {:error, _message} -> row.default
    end
  end

  defp stored(key) do
    Repo.one(from(s in "studio_settings", where: s.key == ^key, select: s.value))
  end

  defp upsert(%{key: key}, value) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "studio_settings",
      [%{key: key, value: Integer.to_string(value), inserted_at: now, updated_at: now}],
      on_conflict: [set: [value: Integer.to_string(value), updated_at: now]],
      conflict_target: :key
    )

    :persistent_term.put({__MODULE__, key}, value)
  end

  defp read(row) do
    case stored(row.key) do
      nil -> row.default
      value -> parse!(row, value)
    end
  end

  @doc """
  Forgets what is cached, so the next read asks the table again.

  The cache is per node and lives for the life of the VM, which is right for a
  running application and wrong for a test that writes a value: a test that
  asserts a default has to be able to start from the table rather than from
  whatever the test before it saved. It is also what a node needs after somebody
  edits `studio_settings` by hand.
  """
  @spec forget() :: :ok
  def forget do
    Enum.each(@settings, &:persistent_term.erase({__MODULE__, &1.key}))
  end
end
