defmodule ExTbpMonty.Mcp.ArgsTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Mcp.Args

  describe "a required string" do
    test "is trimmed and answered" do
      assert Args.required(%{"path" => "  theory/columns.md "}, "path") ==
               {:ok, "theory/columns.md"}
    end

    test "names the argument it is missing" do
      assert Args.required(%{}, "path") == {:error, "`path` is required."}
    end

    test "refuses a blank one rather than passing it on" do
      assert Args.required(%{"path" => "   "}, "path") == {:error, "`path` is required."}
    end

    test "accepts a number as its text" do
      assert Args.required(%{"limit" => 3}, "limit") == {:ok, "3"}
    end
  end

  describe "an optional string" do
    test "is absent when the client did not send it" do
      assert Args.optional(%{}, "area") == {:ok, nil}
    end

    test "is absent when the client sent nothing but space" do
      assert Args.optional(%{"area" => " "}, "area") == {:ok, nil}
    end

    test "is trimmed and answered when it carries something" do
      assert Args.optional(%{"area" => " theory "}, "area") == {:ok, "theory"}
    end

    test "accepts a number as its text" do
      assert Args.optional(%{"section" => 7}, "section") == {:ok, "7"}
    end
  end

  describe "a bounded integer" do
    defp integer(args), do: Args.integer(args, "limit", default: 25, min: 1, max: 200)

    test "is the default when the client did not send it" do
      assert integer(%{}) == {:ok, 25}
    end

    test "is raised to the minimum rather than refused" do
      assert integer(%{"limit" => 0}) == {:ok, 1}
    end

    test "is capped at the maximum rather than refused" do
      assert integer(%{"limit" => 500}) == {:ok, 200}
    end

    test "is read from a string a client decided to send" do
      assert integer(%{"limit" => " 12 "}) == {:ok, 12}
    end

    test "refuses a string that is not a number" do
      assert integer(%{"limit" => "many"}) == {:error, "`limit` must be an integer."}
    end

    test "refuses a value that is not a number at all" do
      assert integer(%{"limit" => [1]}) == {:error, "`limit` must be an integer."}
    end
  end

  describe "an optional object" do
    test "passes a JSON object through" do
      assert Args.object(%{"environment" => %{"seed" => 1}}, "environment") ==
               {:ok, %{"seed" => 1}}
    end

    test "is empty when the client did not send it" do
      assert Args.object(%{}, "environment") == {:ok, %{}}
    end

    test "refuses anything that is not an object" do
      assert Args.object(%{"environment" => "seed: 1"}, "environment") ==
               {:error, "`environment` must be a JSON object."}
    end
  end
end
