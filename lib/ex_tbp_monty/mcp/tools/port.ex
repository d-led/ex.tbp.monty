defmodule ExTbpMonty.Mcp.Tools.Port do
  @moduledoc """
  The port itself: which Python module this Elixir one is, and whether it exists.

  `monty_lookup_module` answers for one target; `monty_port_status` answers for
  the whole checkout; `monty_code_in_doc` follows the source references a
  documentation page makes, which is how a paragraph of theory becomes a list of
  modules that either exist here or do not.
  """

  alias ExTbpMonty.Mcp.{Args, Docs, Port}

  @doc "`monty_lookup_module`: where one target lives here."
  def lookup(args, _ctx) do
    with {:ok, target} <- Args.required(args, "target"),
         {:ok, entry} <- Port.lookup(target) do
      {:ok, %{text: entry_text(entry), structured: entry}}
    end
  end

  @doc "`monty_port_status`: how much of Monty exists here."
  def status(_args, _ctx) do
    status = Port.status()
    summary = status.summary

    {:ok,
     %{
       text: status_text(summary, status.planned),
       structured: status
     }}
  end

  @doc "`monty_code_in_doc`: the modules a page refers to."
  def code_in_doc(args, _ctx) do
    with {:ok, path} <- Args.required(args, "path"),
         {:ok, page} <- page(path) do
      modules = Port.referenced(page.markdown)

      {:ok,
       %{
         text: references_text(page, modules),
         structured: %{path: page.path, online: page.online, modules: modules}
       }}
    end
  end

  defp page(path) do
    case Docs.read(path) do
      {:ok, page} -> {:ok, page}
      {:error, :invalid_path} -> {:error, "`#{path}` is not a page path. See monty_docs_index."}
      {:error, :not_found} -> {:error, "There is no page `#{path}`. See monty_docs_index."}
    end
  end

  defp entry_text(entry) do
    classes =
      entry.classes
      |> Enum.map_join("\n", fn class ->
        "- `#{class.python}` → `#{class.elixir}` (#{class.status})"
      end)

    "#{entry.python}" <>
      if(entry.class, do: "::#{entry.class}", else: "") <>
      "\n→ `#{entry.elixir}` — #{entry.status}" <>
      if(entry.reason, do: " (#{entry.reason})", else: "") <>
      if(classes == "", do: "", else: "\n\n" <> classes)
  end

  defp status_text(summary, planned) do
    header =
      "#{summary.implemented} of #{summary.modules} modules implemented, " <>
        "#{summary.planned} planned, #{summary.excluded} excluded " <>
        "(#{Enum.map_join(summary.by_package, ", ", fn {package, count} -> "#{package}: #{count}" end)})."

    case planned do
      [] -> header
      planned -> header <> "\n\nNot ported yet:\n" <> brief_list(planned, 40)
    end
  end

  defp brief_list(entries, limit) do
    shown = Enum.take(entries, limit)

    Enum.map_join(shown, "\n", fn entry ->
      "- `#{entry.python}` → `#{entry.elixir}`#{if entry.reason, do: " — #{entry.reason}"}"
    end) <> if(length(entries) > limit, do: "\n…and #{length(entries) - limit} more.", else: "")
  end

  defp references_text(page, modules) do
    if modules == [] do
      "`#{page.path}` does not refer to any module by path or dotted target."
    else
      "#{page.title}: #{length(modules)} module(s) referred to.\n\n" <>
        Enum.map_join(modules, "\n", fn module ->
          "- `#{module.reference}` → `#{module.elixir}` (#{module.status})"
        end)
    end
  end
end
