defmodule Monty.Config.Resolvers do
  @moduledoc """
  Resolves the OmegaConf interpolations Monty's configs are written in.

  Composition leaves `${...}` strings exactly as Monty's snapshots have them;
  this module turns them into values:

      ${constants.min_eval_steps}                     a reference into the tree
      ${oc.env:MONTY_DATA}                            an environment variable
      ${oc.env:MONTY_DATA,/tmp/data}                  ... with a default
      ${monty.class:tbp.monty.geometry.Rotation}      a class reference
      ${np.array:[2, 0.5, 0.5]}                       a numeric array
      ${np.ones:3}                                    [1.0, 1.0, 1.0]
      ${np.list_eval:[np.pi / 8, np.pi * 2]}          arithmetic
      ${path.expanduser:~/tbp/data}                   ~ expanded
      ${path.tests:fixtures/cube.json}                inside Monty's tests/

  `monty.class` deserves a note: Monty returns the *class object*, which an
  Elixir process cannot hold. This returns the dotted path as a string and
  leaves the mapping to an Elixir module to `Monty.Config.Registry`, so the
  config file stays readable and an unknown class stays visible instead of
  blowing up during composition.
  """

  alias Monty.Config.Expression

  @type opts :: [env: (String.t() -> String.t() | nil), monty_root: Path.t()]

  @known_prefixes [
    "oc.env:",
    "monty.class:",
    "np.array:",
    "np.ones:",
    "np.list_eval:",
    "path.expanduser:",
    "path.tests:"
  ]

  @max_passes 10

  @doc """
  Resolves every interpolation in a composed config.

  Runs to a fixed point, because a value may reference one that is itself an
  interpolation. A tree that still contains `${` after that is reported as
  unresolved — never silently passed through as a string.
  """
  @spec resolve(map(), opts()) :: {:ok, map()} | {:error, term()}
  def resolve(tree, opts \\ []) do
    opts = normalize_opts(opts)
    resolve_passes(tree, opts, @max_passes)
  end

  @doc "True when any string in the tree still contains an interpolation."
  @spec unresolved?(term()) :: boolean()
  def unresolved?(value) when is_binary(value), do: String.contains?(value, "${")
  def unresolved?(value) when is_list(value), do: Enum.any?(value, &unresolved?/1)

  def unresolved?(value) when is_map(value),
    do: value |> Map.values() |> Enum.any?(&unresolved?/1)

  def unresolved?(_value), do: false

  defp resolve_passes(_tree, _opts, 0), do: {:error, :did_not_converge}

  defp resolve_passes(tree, opts, passes) do
    with {:ok, resolved} <- map_tree(tree, &resolve_leaf(&1, tree, opts)) do
      cond do
        not unresolved?(resolved) -> {:ok, resolved}
        passes == 1 -> {:error, {:unresolved_interpolation, resolved}}
        true -> resolve_passes(resolved, opts, passes - 1)
      end
    end
  end

  defp resolve_leaf(value, root, opts) when is_binary(value) do
    if String.contains?(value, "${") do
      resolve_string(value, root, opts)
    else
      {:ok, value}
    end
  end

  defp resolve_leaf(value, _root, _opts), do: {:ok, value}

  defp resolve_string(value, root, opts) do
    if String.contains?(value, "${") do
      resolve_interpolation(value, root, opts)
    else
      {:ok, value}
    end
  end

  defp resolve_interpolation(value, root, opts) do
    case Regex.run(~r/\$\{([^{}]*)\}/, value) do
      nil ->
        {:error, {:unresolved_interpolation, value}}

      [whole, token] ->
        with {:ok, resolved} <- resolve_token(token, root, opts),
             {:ok, interpolated} <- interpolate(value, whole, resolved) do
          if is_binary(interpolated) do
            resolve_string(interpolated, root, opts)
          else
            {:ok, interpolated}
          end
        end
    end
  end

  # A whole-string reference keeps the value's type; a reference inside a
  # larger string must be scalar, because "a list in the middle of a path" is
  # not a thing Monty writes.
  defp interpolate(whole, whole, resolved), do: {:ok, resolved}

  defp interpolate(value, whole, resolved) when is_binary(resolved),
    do: {:ok, String.replace(value, whole, resolved)}

  defp interpolate(value, whole, resolved) when is_number(resolved),
    do: {:ok, String.replace(value, whole, to_string(resolved))}

  defp interpolate(_value, _whole, resolved),
    do: {:error, {:cannot_interpolate_container, resolved}}

  # -- tokens ---------------------------------------------------------------

  defp resolve_token(token, root, opts) do
    case Enum.find(@known_prefixes, &String.starts_with?(token, &1)) do
      nil -> lookup(token, root)
      prefix -> apply_prefix(prefix, String.replace_prefix(token, prefix, ""), opts)
    end
  end

  defp apply_prefix("oc.env:", argument, opts) do
    {name, default} =
      case String.split(argument, ",", parts: 2) do
        [name] -> {name, nil}
        [name, default] -> {name, default}
      end

    case opts[:env].(name) || default do
      nil -> {:error, {:missing_environment_variable, name}}
      value -> {:ok, value}
    end
  end

  defp apply_prefix("monty.class:", class_path, _opts), do: {:ok, class_path}

  defp apply_prefix("np.array:", expression, _opts), do: Expression.evaluate(expression)

  defp apply_prefix("np.ones:", count, _opts) do
    case Integer.parse(count) do
      {n, ""} -> {:ok, List.duplicate(1.0, n)}
      _other -> {:error, {:invalid_ones_count, count}}
    end
  end

  defp apply_prefix("np.list_eval:", expression, _opts), do: Expression.evaluate(expression)

  defp apply_prefix("path.expanduser:", path, _opts), do: {:ok, Path.expand(path)}

  defp apply_prefix("path.tests:", path, opts) do
    {:ok, Path.join([opts[:monty_root], "tests", path])}
  end

  defp lookup(path, root) do
    case get_in(root, String.split(path, ".")) do
      nil -> {:error, {:unresolved_reference, path}}
      value -> {:ok, value}
    end
  end

  # -- tree traversal -------------------------------------------------------

  defp map_tree(value, fun) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, acc} ->
      case map_tree(nested, fun) do
        {:ok, mapped} -> {:cont, {:ok, Map.put(acc, key, mapped)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp map_tree(value, fun) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case map_tree(item, fun) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp map_tree(value, fun), do: fun.(value)

  defp normalize_opts(opts) do
    [
      env: Keyword.get(opts, :env, &System.get_env/1),
      monty_root: Keyword.get_lazy(opts, :monty_root, fn -> Monty.Config.Source.root() end)
    ]
  end
end
