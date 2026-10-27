defmodule Monty.Studio.ConfigText do
  @moduledoc """
  Writes an experiment config as YAML text that Monty can read.

  Monty's own experiment files are hand-written; a generated one is not, so it
  is emitted mechanically and parsed back through the same loader Monty's files
  go through. The round trip is the point: if this module and
  `Monty.Config.Source` agree on the text, then "the config we built" and "the
  config Monty composes" are the same config, not two representations that
  happen to look alike.

  What is emitted is deliberately narrow, because a config is not a document:

    * a `# @package _global_` header, so the file's body lands at the root;
    * a `defaults:` list, one `- group: option` per line, in the order the base
      experiment lists them — composition order is meaning;
    * the `experiment:` body: its `_target_` and its `config` map.

  Strings are always quoted. `${...}` interpolations carry colons, brackets and
  commas that plain YAML would misread, and quoting everything means the
  emitter has no judgement to get wrong.
  """

  @type config :: %{
          required(:defaults) => [{String.t(), String.t()}],
          required(:experiment) => map(),
          optional(:comments) => [String.t()]
        }

  @doc "Renders a config as the text of an experiment file."
  @spec render(config() | keyword()) :: String.t()
  def render(config) do
    config = Map.new(config)

    [
      "# @package _global_",
      comments(config),
      defaults_line(config.defaults),
      "",
      "experiment:",
      key_lines(config.experiment, 1)
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp comments(%{comments: []}), do: []
  defp comments(%{comments: lines}), do: ["#"] ++ Enum.map(lines, &"# #{&1}") ++ [""]
  defp comments(_config), do: []

  # An empty `defaults:` key with nothing under it parses as `nil`, which is a
  # different thing from an empty list; say which one is meant.
  defp defaults_line([]), do: "defaults: []"

  defp defaults_line(pairs) do
    ["defaults:" | Enum.map(pairs, fn {group, option} -> "  - #{group}: #{scalar(option)}" end)]
  end

  defp key_lines(map, indent) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {key, value} -> value_lines(key, value, indent) end)
  end

  defp value_lines(key, value, indent) when is_map(value) do
    [pad(indent) <> key <> ":" | key_lines(value, indent + 1)]
  end

  defp value_lines(key, [], indent), do: [pad(indent) <> key <> ": []"]

  defp value_lines(key, list, indent) when is_list(list) do
    [pad(indent) <> key <> ":" | Enum.map(list, &(pad(indent + 1) <> "- " <> scalar(&1)))]
  end

  defp value_lines(key, value, indent), do: [pad(indent) <> key <> ": " <> scalar(value)]

  defp scalar(nil), do: "\"\""
  defp scalar(true), do: "true"
  defp scalar(false), do: "false"
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value) when is_float(value), do: Float.to_string(value)
  defp scalar(value) when is_binary(value), do: quoted(value)
  defp scalar(value) when is_atom(value), do: value |> Atom.to_string() |> quoted()

  defp quoted(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  defp pad(indent), do: String.duplicate(" ", indent * 2)
end
