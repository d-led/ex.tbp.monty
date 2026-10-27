defmodule Monty.Config.Composer do
  @moduledoc """
  Composes a Monty experiment config the way Hydra does.

  `compose/2` returns the same tree Monty's `conf/update_snapshots.py` writes to
  `tests/conf/snapshots/<experiment>.yaml`, which is the oracle the parity test
  uses. Interpolations (`${...}`) deliberately stay as strings: Hydra's
  snapshots keep them, and resolving them is `Monty.Config.Resolvers`' job.

  The rules, in the order they matter:

    * a file's body is placed at its package — the `# @package` header, or the
      group path when there is no header;
    * its `defaults:` list is composed first, in order;
    * `_self_` marks where the body is merged among the defaults; without it the
      body comes last;
    * a default may override the package it lands in with `group@package`, and
      such a package is relative to the config doing the overriding.
  """

  alias Monty.Config.Source

  @max_depth 20

  @type tree :: map()

  @doc """
  Composes `experiment` from the Monty checkout.

  Options:

    * `:conf_dir` — the Hydra config directory, defaulting to the checkout's.
  """
  @spec compose(String.t(), keyword()) :: {:ok, tree()} | {:error, term()}
  def compose(experiment, opts \\ []) do
    conf_dir = Keyword.get_lazy(opts, :conf_dir, fn -> Source.conf_dir() end)
    overrides = %{"experiment" => experiment}

    with {:ok, tree} <- compose_group(conf_dir, "", "experiment", nil, overrides, 0) do
      # `conf/hydra/default.yaml` configures Hydra itself (where its run
      # directory goes), not Monty. Monty's snapshots leave it out, and so do
      # we: a run directory for a launcher we do not use is noise in a diff.
      {:ok, Map.delete(tree, "hydra")}
    end
  end

  defp compose_group(_conf_dir, group, option, package_override, _overrides, depth)
       when depth > @max_depth do
    {:error, {:too_deep, group, option, package_override}}
  end

  defp compose_group(conf_dir, group, option, package_override, overrides, depth) do
    with {:ok, config} <- Source.load(conf_dir, group, option) do
      base_package = package_override || config.package || Source.default_package(group)

      with {:ok, tree, saw_self} <-
             compose_defaults(
               config.defaults,
               config.body,
               conf_dir,
               group,
               base_package,
               overrides,
               depth
             ) do
        {:ok, merge_body(tree, saw_self, base_package, config.body)}
      end
    end
  end

  defp compose_defaults(defaults, body, conf_dir, group, base_package, overrides, depth) do
    Enum.reduce_while(defaults, {:ok, %{}, false}, fn default, {:ok, tree, saw_self} ->
      case compose_default(default, conf_dir, group, base_package, overrides, depth) do
        {:ok, :self} ->
          {:cont, {:ok, merge(tree, put_at(base_package, body)), true}}

        {:ok, child_tree} ->
          {:cont, {:ok, merge(tree, child_tree), saw_self}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp compose_default(:self, _conf, _group, _base, _overrides, _depth), do: {:ok, :self}

  defp compose_default(
         {:group, child_group, option, package_spec},
         conf_dir,
         group,
         base,
         overrides,
         depth
       ) do
    with {:ok, child_option} <- apply_override(child_group, option, overrides) do
      child_package = resolve_package(package_spec, base)

      compose_group(
        conf_dir,
        join(group, child_group),
        child_option,
        child_package,
        overrides,
        depth + 1
      )
    end
  end

  defp compose_default(other, _conf, _group, _base, _overrides, _depth) do
    {:error, {:unsupported_default, other}}
  end

  defp merge_body(tree, true, _package, _body), do: tree
  defp merge_body(tree, false, package, body), do: merge(tree, put_at(package, body))

  defp apply_override(group, :missing, overrides) do
    case Map.fetch(overrides, String.trim_leading(group, "/")) do
      {:ok, option} -> {:ok, option}
      :error -> {:error, {:required_group_not_overridden, group}}
    end
  end

  defp apply_override(_group, option, _overrides), do: {:ok, option}

  defp resolve_package(nil, _base), do: nil
  defp resolve_package("_global_", _base), do: []
  defp resolve_package("_here_", base), do: base
  defp resolve_package(package, base), do: base ++ String.split(package, ".")

  # A leading slash means "from the config root", which is how every Monty
  # experiment names its groups; without it the group is relative to the config
  # doing the including (e.g. `hypotheses_updater/burst_sampling_5nn`).
  defp join(_group, "/" <> child), do: child

  defp join(group, child) do
    case String.split(group, "/", trim: true) do
      [] -> child
      segments -> Enum.join(segments ++ [child], "/")
    end
  end

  @doc """
  Deep-merges two trees. Maps merge key by key; a list, a scalar or a `nil`
  replaces what was there, which is Hydra's behaviour and the reason a config
  that wants to *add* to a list spells the whole list.
  """
  @spec merge(tree(), tree()) :: tree()
  def merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  @doc "Places a body at a package path: `experiment.config` becomes a nested map."
  @spec put_at([String.t()], map() | nil) :: tree()
  def put_at([], body), do: body || %{}
  def put_at([segment | rest], body), do: %{segment => put_at(rest, body)}
end
