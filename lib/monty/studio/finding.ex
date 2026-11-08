defmodule Monty.Studio.Finding do
  @moduledoc """
  One thing a person should know about an experiment before running it.

  Findings are the shared vocabulary of the studio: the blueprint (what you
  asked for) and the setup (what the config means) both report in these terms,
  so a page renders one list and a test asserts on one shape.

  Levels are Python's own: an `:error` would stop Monty, a `:warning` is
  accepted by Monty but likely a mistake, and an `:info` is worth knowing (the
  module is real in Monty but not ported here yet).
  """

  @enforce_keys [:level, :code, :message]
  defstruct [:level, :code, :message, :where, :link]

  @type level :: :error | :warning | :info

  @typedoc """
  Where a reader can act on what a finding says.

  A finding that names a page and leaves a person to find it is a finding that
  half-answers: "download the objects" without a way to start the download is
  the same click away as the problem was. `href` is where that click goes.
  """
  @type link :: %{label: String.t(), href: String.t()}

  @type t :: %__MODULE__{
          level: level(),
          code: atom(),
          message: String.t(),
          where: String.t() | nil,
          link: link() | nil
        }

  @doc "A finding about `where` — a config path, a module id or a group name."
  @spec new(level(), atom(), String.t(), String.t() | nil) :: t()
  def new(level, code, message, where \\ nil),
    do: %__MODULE__{level: level, code: code, message: message, where: where}

  @doc "The same finding, with a link to the page that fixes it."
  @spec with_link(t(), String.t(), String.t()) :: t()
  def with_link(%__MODULE__{} = finding, label, href),
    do: %{finding | link: %{label: label, href: href}}

  @doc "Only the findings at the given level."
  @spec at([t()], level()) :: [t()]
  def at(findings, level), do: Enum.filter(findings, &(&1.level == level))

  @doc "Errors, warnings and infos, each in the order they were reported."
  @spec group([t()]) :: %{required(level()) => [t()]}
  def group(findings) do
    %{
      error: at(findings, :error),
      warning: at(findings, :warning),
      info: at(findings, :info)
    }
  end

  @doc "Whether nothing in `findings` would stop Monty."
  @spec acceptable?([t()]) :: boolean()
  def acceptable?(findings), do: at(findings, :error) == []

  @doc "One line for a log or a badge."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{level: level, message: message, where: nil}),
    do: "#{level}: #{message}"

  def describe(%__MODULE__{level: level, message: message, where: where}),
    do: "#{level}: #{message} (#{where})"
end
