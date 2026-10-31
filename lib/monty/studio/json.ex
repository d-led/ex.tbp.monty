defmodule Monty.Studio.Json do
  @moduledoc """
  A JSON value, pretty-printed and coloured for reading.

  A run's config snapshot is the thing a person opens to see what Monty was
  asked to do: which experiment, which modules, which clipping. It arrives as one
  wall of one colour, where the keys are what a reader looks for. So it is
  tokenised here, on the server, and each kind of token gets a class — no
  JavaScript, and no client-side highlighting that leaves the text grey until it
  arrives.

  Everything that is not a token is passed through escaped: the config is Monty's
  data, and this application only ever prints it.
  """

  # One pass, in the order a JSON reader sees them: a string (a key when a colon
  # follows it), a number, a literal, and the punctuation between them. The
  # groups are what get coloured, in the order they appear.
  @tokens ~r/("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b|([{}\[\],:])/

  @doc """
  The value as pretty JSON, with each kind of token in a span of its own.

  Answers markup this module built, with every value escaped where it was built.
  """
  @spec highlight(term()) :: {:safe, iodata()}
  def highlight(value), do: value |> Jason.encode!(pretty: true) |> colour()

  @doc """
  Pretty JSON text, coloured.

  Separate from `highlight/1` because the colouring is a function of the text: it
  needs no database, no page and no value to encode.
  """
  @spec colour(String.t()) :: {:safe, iodata()}
  def colour(json) when is_binary(json), do: {:safe, tokenise(json, 0, [])}

  defp tokenise(json, offset, acc) do
    case Regex.run(@tokens, json, return: :index, offset: offset) do
      nil ->
        Enum.reverse([escape(binary_part(json, offset, byte_size(json) - offset)) | acc])

      [{start, length} | groups] ->
        before = escape(binary_part(json, offset, start - offset))
        acc = [group_spans(json, start, length, groups), before | acc]

        tokenise(json, start + length, acc)
    end
  end

  # Each participating group becomes a span, and the text between groups — the
  # whitespace of pretty JSON — is kept exactly as it is.
  defp group_spans(json, match_start, match_length, groups) do
    groups
    |> Enum.with_index(1)
    |> Enum.filter(fn {group, _index} -> participated?(group) end)
    |> Enum.reduce({match_start, []}, fn {{start, length}, index}, {cursor, spans} ->
      gap = escape(binary_part(json, cursor, start - cursor))
      token = binary_part(json, start, length)

      {start + length, [coloured(token, class_of(index, token, groups)), gap | spans]}
    end)
    |> then(fn {cursor, spans} ->
      tail = escape(binary_part(json, cursor, match_start + match_length - cursor))
      Enum.reverse([tail | spans])
    end)
  end

  defp key?([_string, colon | _rest]), do: participated?(colon)
  defp key?(_no_colon), do: false

  # A group that did not take part answers `{-1, 0}`, or `nil` on some paths; both
  # mean "there was nothing here".
  defp participated?(nil), do: false
  defp participated?({start, _length}), do: start >= 0

  # A string is a key when a colon follows it, and a value otherwise — and the
  # colon group is only there when it took part, because the engine trims the
  # groups after the last one of a match.
  defp class_of(1, _token, groups) do
    if key?(groups), do: "text-info", else: "text-success"
  end

  defp class_of(2, _token, _groups), do: "text-base-content/40"
  defp class_of(3, _token, _groups), do: "text-warning"

  # `null` says "not set", which reads as absence rather than as a value, so it is
  # muted like punctuation.
  defp class_of(4, "null", _groups), do: "text-base-content/50"
  defp class_of(4, _literal, _groups), do: "text-warning"
  defp class_of(_punctuation, _token, _groups), do: "text-base-content/40"

  defp coloured(token, class), do: [~s(<span class="), class, ~s(">), escape(token), "</span>"]

  defp escape(text), do: Plug.HTML.html_escape_to_iodata(text)
end
