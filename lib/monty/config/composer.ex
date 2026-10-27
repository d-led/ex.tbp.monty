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
    * `:overrides` — group overrides keyed by group path without a leading
      slash, as Hydra takes them on the command line
      (`%{"monty/learning_module" => "evidence_1lm_nn5_dod003"}`).
  """
  @spec compose(String.t(), keyword()) :: {:ok, tree()} | {:error, term()}
  def compose(experiment, opts \\ []) do
    conf_dir = Keyword.get_lazy(opts, :conf_dir, fn -> Source.conf_dir() end)
    overrides = Map.put(Keyword.get(opts, :overrides, %{}), "experiment", experiment)

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
      compose_config(conf_dir, config, base_package, group, overrides, depth)
    end
  end

  @doc """
  Composes a config written as text, as if Monty shipped it.

  A generated experiment is an experiment file: Monty's launcher composes it
  *through* its root config, which is where `constants` and the rest of the
  top-level settings come from. So the text is composed as the root config's
  `experiment` choice rather than on its own — otherwise a generated config
  would resolve fewer interpolations than the identical file would in Monty's
  own tree.
  """
  @spec compose_yaml(String.t(), keyword()) :: {:ok, tree()} | {:error, term()}
  def compose_yaml(text, opts \\ []) do
    conf_dir = Keyword.get_lazy(opts, :conf_dir, fn -> Source.conf_dir() end)

    with {:ok, config} <- Source.load_text(text) do
      overrides =
        opts
        |> Keyword.get(:overrides, %{})
        |> Map.put("experiment", {:config, config})

      with {:ok, tree} <- compose_group(conf_dir, "", "experiment", nil, overrides, 0) do
        {:ok, Map.delete(tree, "hydra")}
      end
    end
  end

  @doc "Composes a config from a file outside Monty's config tree."
  @spec compose_file(Path.t(), keyword()) :: {:ok, tree()} | {:error, term()}
  def compose_file(path, opts \\ []) do
    with {:ok, text} <- File.read(path) do
      compose_yaml(text, opts)
    end
  end

  # `group` is only needed to resolve a relative default; a config composed
  # from text has no group of its own, and a generated config names its groups
  # absolutely, the way Monty's experiment files do.
  defp compose_config(conf_dir, config, base_package, group, overrides, depth) do
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
      child_group_path = join(group, child_group)

      case child_option do
        # An override may carry a config that was never a file on disk — a
        # generated experiment — in which case it is composed in place of the
        # group option it replaces.
        {:config, config} ->
          compose_config(
            conf_dir,
            config,
            child_package || config.package || Source.default_package(child_group_path),
            child_group_path,
            overrides,
            depth + 1
          )

        option ->
          compose_group(conf_dir, child_group_path, option, child_package, overrides, depth + 1)
      end
    end
  end

  defp compose_default(other, _conf, _group, _base, _overrides, _depth) do
    {:error, {:unsupported_default, other}}
  end

  defp merge_body(tree, true, _package, _body), do: tree
  defp merge_body(tree, false, package, body), do: merge(tree, put_at(package, body))

  # An override wins over the option a defaults list names; a `??`-marked group
  # has no option of its own, so it needs one.
  defp apply_override(group, option, overrides) do
    case Map.fetch(overrides, String.trim_leading(group, "/")) do
      {:ok, {:config, _config} = override} ->
        {:ok, override}

      {:ok, override} ->
        {:ok, override}

      :error when option == :missing ->
        {:error, {:required_group_not_overridden, group}}

      :error ->
        {:ok, option}
    end
  end

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
