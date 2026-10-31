defmodule Monty.Studio.JsonTest do
  @moduledoc """
  A config snapshot is read, so it is coloured: keys one way, values another, and
  anything that is not a token left exactly as it was. The text is Monty's data,
  so it is escaped on the way out.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Json

  @value %{"seed" => 42, "on" => true, "nothing" => nil, "name" => "a<b"}

  defp markup(value), do: value |> Json.highlight() |> elem(1) |> IO.iodata_to_binary()

  defp colour_of(html, text) do
    case Regex.run(~r/<span class="([^"]+)">#{Regex.escape(text)}<\/span>/, html) do
      [_all, class] -> class
      nil -> :plain
    end
  end

  test "a key and the value it holds are coloured differently" do
    html = markup(@value)

    assert colour_of(html, "&quot;seed&quot;") == "text-info"
    assert colour_of(html, "42") == "text-warning"
  end

  test "a string value is coloured as a string, and a literal as itself" do
    html = markup(@value)

    assert colour_of(html, "&quot;a&lt;b&quot;") == "text-success"
    assert colour_of(html, "true") == "text-warning"
    assert colour_of(html, "null") == "text-base-content/50"
    assert colour_of(html, "{") == "text-base-content/40"
  end

  test "the formatting is JSON's own, with nothing added between the tokens" do
    html = markup(@value)
    text = Regex.replace(~r/<\/?span[^>]*>/, html, "")

    # The document Jason wrote, with the spans taken out: colouring must not
    # change a character of what it colours.
    escaped =
      IO.iodata_to_binary(Plug.HTML.html_escape_to_iodata(Jason.encode!(@value, pretty: true)))

    assert text == escaped
  end

  test "a value that looks like markup is escaped, not rendered" do
    html = markup(%{"name" => "<script>alert(1)</script>"})

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "the value it was given is a JSON document, so a config reads as it was written" do
    html = markup(%{"experiment" => %{"config" => %{"seed" => 1}}})

    assert colour_of(html, "&quot;experiment&quot;") == "text-info"
    assert colour_of(html, "1") == "text-warning"
  end
end
