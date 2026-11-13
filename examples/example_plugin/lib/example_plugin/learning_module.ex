defmodule ExamplePlugin.LearningModule do
  @moduledoc """
  A learning module offered by this node: the framework's own evidence threshold,
  read once from the environment.

  A learning module is **advertised rather than routed** (`MontyPlugin` on
  kinds): a step asks it thousands of times over hypotheses and a k-d tree, so a
  cluster cannot call it across a node — it says what it is, at which version,
  and the caller compiles the module in. What this plugin holds is the decision
  the module makes about one step: how much evidence a hypothesis needs to be
  worth updating, which is
  `Monty.Frameworks.Models.EvidenceMatching.LearningModule`'s own rule.

  ## The settings, and why they are parsed at boot

  `EVIDENCE_THRESHOLD` takes the spelling the framework's configs use — a number,
  `"mean"`, `"median"`, `"all"`, `"[n]%"`, or `"x_percent_threshold"` — and the
  last is read against `X_PERCENT_THRESHOLD`. Both default to what Monty's own
  learning module configs set (`"x_percent_threshold"`, 20).

  A threshold is configuration, so a wrong one is refused where the module is
  built rather than answering a threshold that is quietly not the one asked for:
  `from_settings/1` answers `{:error, sentence}` and the process that offers this
  plugin does not start.
  """

  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule, as: Evidence

  @default_threshold "x_percent_threshold"
  @default_percent 20

  defstruct [:threshold]

  @type t :: %__MODULE__{threshold: Evidence.config()}

  @doc "The name a cluster registers it under."
  @spec name() :: String.t()
  def name, do: "example_plugin.evidence_threshold"

  @doc "What a cluster asks about it."
  @spec describe() :: MontyPlugin.description()
  def describe do
    %{
      "name" => name(),
      "kind" => :learning_module,
      "version" => ExamplePlugin.version(),
      "placement" => :anywhere,
      "needs" => [:monty]
    }
  end

  @doc """
  The module, with its setting parsed.

  `:threshold` and `:x_percent_threshold` override the environment, which is how
  a test says what it means instead of exporting a variable.
  """
  @spec from_settings(keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_settings(options \\ []) do
    threshold = option(options, :threshold) || env("EVIDENCE_THRESHOLD", @default_threshold)
    percent = option(options, :x_percent_threshold) || percent_from_env()

    case Evidence.parse_config(threshold, percent) do
      {:ok, config} -> {:ok, %__MODULE__{threshold: config}}
      {:error, invalid} -> {:error, Exception.message(invalid)}
    end
  end

  @doc """
  How much evidence a hypothesis needs this step.

  `evidence` is the column of evidence the hypotheses hold, and the answer is the
  lowest value a hypothesis may have and still be updated; `nil` is what the
  ported rule answers when the setting asks for a percentage of a field that has
  no best hypothesis yet.
  """
  @spec evidence_update_threshold(t(), number(), [number()]) :: float() | nil
  def evidence_update_threshold(%__MODULE__{threshold: config}, max_global_evidence, evidence),
    do: Evidence.evidence_update_threshold(config, max_global_evidence, evidence)

  defp option(options, key), do: Keyword.get(options, key)

  defp env(variable, default), do: System.get_env(variable, default)

  defp percent_from_env do
    case Integer.parse(System.get_env("X_PERCENT_THRESHOLD", "")) do
      {percent, ""} -> percent
      _unset_or_not_a_number -> @default_percent
    end
  end
end
