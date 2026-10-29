defmodule ExTbpMontyWeb.JobsLive do
  @moduledoc """
  The queue: every run job Oban holds, and the run it is for.

  The Runs page answers "what did this run decide". This page answers the
  question that comes before it — "where is it" — because a run that is queued or
  failing has no decision to show and, without this page, looks like a run that
  never happened. A job row links to its run whenever the run has a record.

  Refreshing is a click, not a timer: Oban is the source of truth, and a page
  that polls would be guessing how often to ask.
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Studio.Jobs

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(counts: %{}, limit: 50)
     |> stream_configure(:jobs, dom_id: &"job-#{&1.id}")
     |> stream(:jobs, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="mx-auto max-w-5xl space-y-6">
        <header class="space-y-2">
          <h1 class="text-3xl font-semibold tracking-tight">Queue</h1>
          <p class="text-base-content/70">
            Every run is an Oban job on the <code>studio</code>
            queue. A job that
            has started has a <.link navigate={~p"/runs"} class="link link-primary">run</.link>
            to open; a job that has not is only visible here.
          </p>
        </header>

        <div class="flex flex-wrap items-center gap-2">
          <span :for={{state, count} <- Enum.sort(@counts)} class="badge badge-ghost">
            {state} {count}
          </span>
          <span :if={@counts == %{}} class="text-sm text-base-content/60">
            No jobs yet.
          </span>
          <button id="refresh" phx-click="refresh" class="btn btn-sm ml-auto">
            <.icon name="hero-arrow-path-mini" class="size-4" /> Refresh
          </button>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>job</th>
                <th>state</th>
                <th>worker</th>
                <th>attempt</th>
                <th>inserted</th>
                <th>run</th>
              </tr>
            </thead>
            <tbody id="jobs" phx-update="stream">
              <tr id="jobs-empty" class="hidden only:table-row">
                <td colspan="6" class="text-base-content/60">The queue is empty.</td>
              </tr>
              <tr :for={{dom_id, job} <- @streams.jobs} id={dom_id}>
                <td class="font-mono">{job.id}</td>
                <td>
                  <span class={["badge badge-sm", state_class(job.state)]}>
                    {job.state}
                  </span>
                  <span :if={job.error} class="block text-xs text-error">{job.error}</span>
                </td>
                <td class="font-mono text-xs">{job.worker}</td>
                <td class="font-mono text-xs">{job.attempt}/{job.max_attempts}</td>
                <td class="text-xs">{moment(job.inserted_at)}</td>
                <td class="text-xs">
                  <%= cond do %>
                    <% job.run_status -> %>
                      <.link
                        navigate={~p"/runs/#{job.run_id}"}
                        class="link link-primary font-mono"
                      >
                        {short(job.run_id)}
                      </.link>
                      <span class="text-base-content/60">({job.run_status})</span>
                    <% job.run_id -> %>
                      <%!-- The job still names a run, but the run's record is gone:
                      show which one it was, without linking to nothing. --%>
                      <span class="font-mono text-base-content/40">{short(job.run_id)}</span>
                      <span class="text-base-content/40">(deleted)</span>
                    <% true -> %>
                      <span class="text-base-content/40">—</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    socket
    |> assign(counts: Jobs.counts())
    |> stream(:jobs, Jobs.list(limit: socket.assigns.limit), reset: true)
  end

  defp state_class("completed"), do: "badge-success"
  defp state_class("executing"), do: "badge-info"
  defp state_class("retryable"), do: "badge-warning"
  defp state_class("discarded"), do: "badge-error"
  defp state_class(_other), do: "badge-ghost"

  defp moment(nil), do: "—"
  defp moment(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

  # A run id is a UUID; the page shows what distinguishes it, and links to all of
  # it.
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
end
