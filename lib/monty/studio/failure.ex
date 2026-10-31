defmodule Monty.Studio.Failure do
  @moduledoc """
  What stopped a run, said in words a person can act on.

  A record keeps the reason in whatever shape ended the run: a sentence we wrote
  ("it was stopped before it finished"), an exception's message, or — worst for
  reading — `Exception.format/3`, which is a stacktrace with a dump of internal
  module names. A page that showed the last one would be asking someone to read
  Elixir to find out that the world could not be posed.

  So every reason passes through here first: `what` is one sentence, `hint` says
  what to do about it when there is something to do, and `technical` keeps the
  original untouched for the reader who does want it.
  """

  @typedoc """
  A reason, explained.

  `technical` is `nil` when the reason was already plain English: there is
  nothing to expand, and a "details" fold that only repeats the sentence is
  noise.
  """
  @type explained :: %{
          what: String.t(),
          hint: String.t() | nil,
          technical: String.t() | nil
        }

  @simulator_hint "The simulator is the first thing to check: the run needs a world it can step."

  @doc """
  Explains the reason a run stopped.

  A reason that is already a sentence stays one; an exception becomes a sentence
  about the world rather than about Elixir.
  """
  @spec explain(String.t() | nil) :: explained()
  def explain(nil), do: %{what: "It stopped without saying why.", hint: nil, technical: nil}

  def explain(reason) when is_binary(reason) do
    case exception(reason) do
      {kind, message} -> translated(kind, message, reason)
      nil -> bare(reason)
    end
  end

  # `Exception.format/3` starts with "** (Kind) message" and puts the stacktrace
  # underneath, indented. Both halves are kept: the message is what we explain,
  # the whole thing is what "technical details" unfolds.
  defp exception(reason) do
    case Regex.run(~r/^\*\* \(([A-Za-z0-9_.]+)\) ?(.*)$/m, reason) do
      [_all, kind, message] -> {kind, String.trim(message)}
      nil -> nil
    end
  end

  # A reason that was never an exception: either one of our own sentences, or a
  # value somebody inspected into the record.
  defp bare(reason) do
    case weak_tuple(reason) do
      nil -> plain(reason)
      text -> %{what: text, hint: @simulator_hint, technical: reason}
    end
  end

  # Already our own words — a stop, an end, an abandoned record. Nothing to
  # translate, nothing to unfold.
  defp plain(reason), do: %{what: reason, hint: nil, technical: nil}

  defp translated(kind, message, reason) do
    case about(kind, message) do
      {what, hint} -> %{what: what, hint: hint, technical: reason}
      nil -> %{what: sentence(kind, message), hint: nil, technical: reason}
    end
  end

  # The ones worth a sentence of their own, because the exception's own words are
  # about machinery the reader has never seen. Matched on what was said rather
  # than on where it was raised, so a move of the code does not lose the message.
  defp about(_kind, message) do
    cond do
      message =~ "sets a pose outright" or message =~ "stand-in world" ->
        {"This world cannot be posed directly, so the agent cannot be placed in it.",
         "Run it against a simulator — the monty or habitat world — or pick an experiment whose agent starts where the stand-in puts it."}

      message =~ "no such file" or message =~ "enoent" ->
        {"A file the run needs is not there.",
         "The prerequisites page lists what an experiment expects to find on disk."}

      true ->
        nil
    end
  end

  defp weak_tuple(message) do
    case Regex.run(~r/^\{:simulator_exited, (\d+)\}$/, message) do
      [_, code] -> "The simulator stopped while the run was stepping (exit code #{code})."
      nil -> nil
    end
  end

  # Every other exception keeps its own sentence: the message is written by
  # whoever raised it, and it is usually the most useful thing there is — it just
  # does not need the stacktrace underneath it on a page meant to be read.
  defp sentence(kind, ""), do: "The run stopped with an error (#{kind})."
  defp sentence(_kind, message), do: first_sentence(message)

  defp first_sentence(message) do
    message
    |> String.split("\n")
    |> List.first()
    |> String.replace_prefix("** ", "")
    |> String.trim()
  end
end
