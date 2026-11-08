defmodule Monty.Config.Expression do
  @moduledoc """
  Evaluates the tiny arithmetic dialect Monty's configs use.

  Monty has an OmegaConf resolver, `np.list_eval`, that runs Python's `eval` over
  each item of a list, and its configs rely on it for things like
  `${np.list_eval:[np.pi / 8, np.pi * 2, np.pi * 2]}`. Running Python is not an
  option, so this module parses exactly the language those entries use:

    * number literals (`8`, `0.7`, `1e-3`)
    * `np.pi`
    * `+`, `-`, `*`, `/` with the usual precedence, and parentheses
    * a list of expressions in brackets

  Anything outside that grammar is an error, which is the point: an evaluator
  that quietly accepts more would be an evaluator we cannot reason about.
  """

  @type value :: number() | [value()]

  @doc """
  Evaluates a bare expression.

      iex> Monty.Config.Expression.evaluate("np.pi / 8")
      0.39269908169872414

      iex> Monty.Config.Expression.evaluate("[1, 2 * 3]")
      [1.0, 6.0]
  """
  @spec evaluate(String.t()) :: {:ok, value()} | {:error, term()}
  def evaluate(source) do
    with {:ok, tokens} <- tokenize(source),
         {:ok, value, []} <- expression(tokens) do
      {:ok, value}
    else
      {:ok, _value, rest} -> {:error, {:unexpected_tokens, rest}}
      {:error, _reason} = error -> error
    end
  end

  # -- lexer ----------------------------------------------------------------

  defp tokenize(source), do: lex(String.to_charlist(source), [])

  defp lex([], tokens), do: {:ok, Enum.reverse(tokens)}

  defp lex([char | rest], tokens) when char in [?\s, ?\n, ?\t, ?\r], do: lex(rest, tokens)

  defp lex([char | rest], tokens) when char in [?+, ?-, ?*, ?/, ?(, ?), ?[, ?], ?,],
    do: lex(rest, [char | tokens])

  defp lex([?n, ?p, ?., ?p, ?i | rest], tokens), do: lex(rest, [:np_pi | tokens])

  defp lex([char | _rest] = source, tokens) when char in ?0..?9 do
    {number, rest} = take_number(source, [])
    lex(rest, [{:number, number} | tokens])
  end

  defp lex([?., char | _rest] = source, tokens) when char in ?0..?9 do
    {number, rest} = take_number(source, [])
    lex(rest, [{:number, number} | tokens])
  end

  defp lex(other, _tokens), do: {:error, {:unexpected_input, other}}

  defp take_number(source, taken) do
    {digits, rest} = Enum.split_while(source, &number_char?/1)
    number = taken |> Enum.reverse() |> Enum.concat(digits) |> to_string() |> parse_number()
    {number, rest}
  end

  defp number_char?(char), do: char in ?0..?9 or char in [?., ?e, ?E, ?+, ?-]

  defp parse_number(text) do
    case Integer.parse(text) do
      {integer, ""} -> integer * 1.0
      _other -> String.to_float(text)
    end
  end

  # -- parser ---------------------------------------------------------------

  defp expression([char | rest]) when char == ?[, do: list(rest, [])

  defp expression(tokens), do: additive(tokens)

  defp list([], _items), do: {:error, :unclosed_list}

  defp list([char | rest], items) when char == ?] do
    {:ok, Enum.reverse(items), rest}
  end

  defp list(tokens, items) do
    with {:ok, value, rest} <- additive(tokens) do
      case rest do
        [char | rest] when char == ?, -> list(rest, [value | items])
        [char | rest] when char == ?] -> {:ok, Enum.reverse([value | items]), rest}
        other -> {:error, {:expected_comma_or_bracket, other}}
      end
    end
  end

  defp additive(tokens) do
    with {:ok, left, rest} <- multiplicative(tokens) do
      additive_rest(left, rest)
    end
  end

  defp additive_rest(left, [?+ | rest]) do
    with {:ok, right, rest} <- multiplicative(rest), do: additive_rest(left + right, rest)
  end

  defp additive_rest(left, [?- | rest]) do
    with {:ok, right, rest} <- multiplicative(rest), do: additive_rest(left - right, rest)
  end

  defp additive_rest(left, rest), do: {:ok, left, rest}

  defp multiplicative(tokens) do
    with {:ok, left, rest} <- unary(tokens) do
      multiplicative_rest(left, rest)
    end
  end

  defp multiplicative_rest(left, [?* | rest]) do
    with {:ok, right, rest} <- unary(rest), do: multiplicative_rest(left * right, rest)
  end

  defp multiplicative_rest(left, [?/ | rest]) do
    with {:ok, right, rest} <- unary(rest) do
      if right == 0,
        do: {:error, :division_by_zero},
        else: multiplicative_rest(left / right, rest)
    end
  end

  defp multiplicative_rest(left, rest), do: {:ok, left, rest}

  defp unary([?- | rest]) do
    with {:ok, value, rest} <- unary(rest), do: {:ok, -value, rest}
  end

  defp unary([?+ | rest]), do: unary(rest)

  defp unary([char | rest]) when char == ?( do
    with {:ok, value, rest} <- additive(rest) do
      case rest do
        [closing | rest] when closing == ?) -> {:ok, value, rest}
        other -> {:error, {:expected_closing_parenthesis, other}}
      end
    end
  end

  defp unary([{:number, number} | rest]), do: {:ok, number, rest}
  defp unary([:np_pi | rest]), do: {:ok, :math.pi(), rest}

  defp unary(other), do: {:error, {:unexpected_tokens, other}}
end
