defmodule ExTbpMonty.Mcp do
  @moduledoc """
  The Model Context Protocol server: its identity, the protocol revisions it
  speaks, and what it tells a client before the client picks a tool.

  What a message *means* is `ExTbpMontyWeb.Mcp.Protocol`; how it travels is
  `ExTbpMontyWeb.McpController`; the tools are `ExTbpMonty.Mcp.Tools` and the
  modules under it. This module holds the parts all of them agree on, so a
  version or a name is written once.

  What the server is for: an assistant that has to connect what the Thousand
  Brains Project *says* — its theory, its documentation, its roadmap — with what
  this application *does*: which of Monty's Python modules are ported here, what
  an experiment is actually configured to be, and how to define and start one.

  Unlike the mirror this shape was borrowed from, this server is not read-only.
  Two tools write: one saves an experiment draft, one queues a run. Both are the
  studio's own operations — a file in the studio's draft directory, a job in the
  studio queue — and neither reaches beyond them.
  """

  # Newest first. `initialize` answers with what the client asked for when this
  # server speaks it, and with the first entry when it does not, which is what
  # the lifecycle section of the specification asks a server to do.
  @protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)

  @doc "Protocol revisions this server can talk."
  @spec protocol_versions() :: [String.t()]
  def protocol_versions, do: @protocol_versions

  @doc "The newest revision, used when the client asks for one we do not know."
  @spec latest_protocol_version() :: String.t()
  def latest_protocol_version, do: hd(@protocol_versions)

  @doc "Whether this server speaks a revision."
  @spec protocol_version?(term()) :: boolean()
  def protocol_version?(version) when is_binary(version), do: version in @protocol_versions
  def protocol_version?(_version), do: false

  @doc "The revision to answer an `initialize` with."
  @spec negotiate(term()) :: String.t()
  def negotiate(requested) do
    if protocol_version?(requested), do: requested, else: latest_protocol_version()
  end

  @doc "The `serverInfo` object of an `initialize` result."
  @spec server_info() :: map()
  def server_info do
    %{"name" => "monty-studio", "title" => "Monty studio", "version" => version()}
  end

  @doc """
  What a client is told before it picks a tool.

  Short on purpose — a model pays for every token and the tool descriptions
  already say what each tool does. This says the three things a model cannot
  infer: where the knowledge comes from, that the studio's own numbers are
  authoritative for *this* port, and that a run comes back as a link.
  """
  @spec instructions() :: String.t()
  def instructions do
    """
    This server connects the Thousand Brains Project's documentation to the Monty \
    port in this application.

    Ground an answer before giving it. monty_search_docs finds the passage in \
    Monty's own docs (theory, how Monty works, how to use it, future work) and \
    returns the page it came from with a link to the published page; \
    monty_read_doc reads a whole page. monty_roadmap lists future-work tasks with \
    their status, scope and skills.

    For code, monty_lookup_module says where a Python class or file lives here — \
    its Elixir module, and whether it is implemented, planned or excluded — and \
    monty_code_in_doc takes a doc page and resolves the modules it refers to, \
    which is the fastest way to go from a paragraph of theory to source.

    For experiments, monty_list_experiments and monty_describe_experiment say what \
    a config is made of: sensors, learning modules, the connections between them, \
    epochs, seed, and which of those classes are ported. \
    monty_experiment_options and monty_read_option show the parameters a config \
    can choose from. To make one, call monty_preview_experiment with a base \
    experiment and your changes, then monty_create_experiment to save it, then \
    monty_run_experiment — which queues the run and answers with a link you can \
    open; poll monty_run_report with the run id for what the run did.

    Numbers about a run, a setup or a port status are the studio's, not the \
    docs': where they disagree, say so rather than averaging them.
    """
  end

  defp version do
    case Application.spec(:ex_tbp_monty, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
