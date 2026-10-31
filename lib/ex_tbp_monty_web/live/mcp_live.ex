defmodule ExTbpMontyWeb.McpLive do
  @moduledoc """
  How to point an editor at this application.

  The MCP server is one HTTP endpoint, so "configuration" is a URL and a name.
  What this page adds is the part that is easy to get wrong: *which* URL — the
  port this instance actually answers on, not the one in a document written for
  somebody else's machine — and the shape the editor wants it in today.
  """

  use ExTbpMontyWeb, :live_view

  @tool_families [
    {"Documentation", "monty_search_docs · monty_read_doc · monty_docs_index"},
    {"Roadmap", "monty_roadmap · monty_roadmap_task"},
    {"The port", "monty_lookup_module · monty_port_status · monty_code_in_doc"},
    {"Experiments",
     "monty_list_experiments · monty_describe_experiment · monty_experiment_options · " <>
       "monty_read_option · monty_preview_experiment · monty_create_experiment · " <>
       "monty_run_experiment"},
    {"Runs", "monty_list_runs · monty_run_report"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    endpoint = endpoint(socket)

    {:ok,
     assign(socket,
       endpoint: endpoint,
       server_name: "monty-studio",
       config: config_text("monty-studio", endpoint),
       tool_families: @tool_families,
       tool_count: tool_count()
     )}
  end

  # Counted from the list above rather than written down beside it: a tool added
  # to the server should not need this page edited, and a number in prose is
  # wrong by the next commit.
  defp tool_count do
    @tool_families
    |> Enum.map(fn {_family, tools} -> length(String.split(tools, "·")) end)
    |> Enum.sum()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header id="intro" class="space-y-2">
        <h1 class="text-3xl font-semibold tracking-tight">MCP</h1>
        <p class="max-w-3xl text-base-content/70">
          The same studio, answering an assistant: one JSON-RPC message in, one answer out,
          over a plain HTTP URL. Ask what Monty's documentation says, where a Python class
          lives here, what an experiment is configured to be — or define and queue a run
          without opening a browser.
        </p>
      </header>

      <section id="mcp-endpoint" class="space-y-2">
        <h2 class="text-lg font-semibold tracking-tight">This instance's endpoint</h2>
        <p class="max-w-3xl text-sm text-base-content/70">
          Taken from the address you are reading this on, because that is the port this
          instance answers on — <code class="font-mono text-xs">4001</code> in this
          workspace, <code class="font-mono text-xs">4000</code> in the container.
        </p>
        <p class="flex flex-wrap items-center gap-2">
          <code id="mcp-url" class="rounded-field bg-base-200 px-2 py-1 font-mono text-sm">
            {@endpoint}
          </code>
          <.copy_button id="copy-mcp-url" what="the endpoint" value={@endpoint} />
        </p>
      </section>

      <section id="mcp-config" class="space-y-2">
        <h2 class="text-lg font-semibold tracking-tight">VS Code</h2>
        <p class="max-w-3xl text-sm text-base-content/70">
          In a workspace, VS Code reads <code class="font-mono text-xs">.vscode/mcp.json</code>;
          this repository ships that file already filled in for the development port. Paste
          this into another workspace, or into your user settings, to reach this instance:
        </p>

        <div class="overflow-hidden rounded-box border border-base-300 bg-base-100">
          <div class="flex items-center justify-between gap-2 border-b border-base-300 px-3 py-1.5">
            <span class="font-mono text-xs text-base-content/60">.vscode/mcp.json</span>
            <.copy_button id="copy-mcp-config" what="the configuration" value={@config} />
          </div>

          <pre
            id="mcp-config-text"
            phx-no-curly-interpolation
            class="overflow-x-auto px-3 py-2 font-mono text-xs leading-relaxed"
          ><%= @config %></pre>
        </div>

        <p class="max-w-3xl text-sm text-base-content/70">
          Then ask the assistant something that needs Monty, and pick
          <code class="font-mono text-xs">{@server_name}</code>
          when the editor offers its
          tools. A client that takes a bare URL takes
          <code class="font-mono text-xs">{@endpoint}</code>
          instead.
        </p>
      </section>

      <section id="mcp-tools" class="space-y-2">
        <h2 class="text-lg font-semibold tracking-tight">What it answers</h2>
        <p class="max-w-3xl text-sm text-base-content/70">
          {@tool_count} tools, and the answers come from the same places the pages do: Monty's
          documentation and future-work files, the checked-in module map, the composed config
          tree, and the run records. A documentation answer carries the page's path and its
          published address, so a claim can be checked rather than believed.
        </p>
        <dl class="grid gap-2 sm:grid-cols-2">
          <div
            :for={{family, tools} <- @tool_families}
            id={"mcp-tools-#{String.downcase(family) |> String.replace(" ", "-")}"}
            class="rounded-box border border-base-300 bg-base-100 p-3"
          >
            <dt class="text-sm font-medium">{family}</dt>
            <dd class="mt-1 font-mono text-xs leading-relaxed text-base-content/60">{tools}</dd>
          </div>
        </dl>
        <p class="text-sm text-base-content/70">
          The full contract — where each answer is read from, and what it refuses to guess —
          is in <a
            href="https://github.com/d-led/ex.tbp.monty/blob/main/docs/mcp.md"
            class="link link-hover"
          >
            docs/mcp.md
          </a>.
        </p>
      </section>
    </Layouts.app>
    """
  end

  # The port this instance answers on, as the browser sees it. A release behind a
  # proxy speaks `https://…` with no port, and that is the URL its clients want.
  defp endpoint(socket) do
    case socket.host_uri do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        "#{scheme}://#{host}#{port_part(scheme, port)}/mcp"

      _unknown_origin ->
        ExTbpMontyWeb.Endpoint.url() <> "/mcp"
    end
  end

  defp port_part(scheme, port) when scheme == "http" and port == 80, do: ""
  defp port_part(scheme, port) when scheme == "https" and port == 443, do: ""
  defp port_part(_scheme, nil), do: ""
  defp port_part(_scheme, port), do: ":#{port}"

  # Exactly what an editor reads, in the shape it reads it today.
  defp config_text(name, endpoint) do
    """
    {
      "servers": {
        "#{name}": {
          "type": "http",
          "url": "#{endpoint}"
        }
      }
    }
    """
  end

  attr :id, :string, required: true
  attr :what, :string, required: true, doc: "what is being copied, for the button's label"
  attr :value, :string, required: true

  # Copying is the browser's job, so the value travels in a data attribute and a
  # colocated hook does the rest: no round trip, and no server state about what
  # has been copied.
  def copy_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-hook=".Copy"
      data-value={@value}
      title={"Copy #{@what}"}
      class="btn btn-ghost btn-xs gap-1.5 font-normal text-base-content/60 hover:text-base-content"
    >
      <.icon name="hero-clipboard-mini" class="size-3.5" /> copy
    </button>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
      export default {
        mounted() {
          this.el.addEventListener("click", async () => {
            try {
              await navigator.clipboard.writeText(this.el.dataset.value)
            } catch (_error) {
              return
            }
            const label = this.el.querySelector("span, :scope > :last-child")
            if (label) label.textContent = "copied"
            setTimeout(() => { if (label) label.textContent = "copy" }, 1200)
          })
        }
      }
    </script>
    """
  end
end
