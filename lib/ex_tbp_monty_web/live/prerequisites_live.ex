defmodule ExTbpMontyWeb.PrerequisitesLive do
  @moduledoc """
  The files an experiment needs, and their download progress.

  Monty's prerequisites are large archives; the page shows them arriving
  instead of a silent `curl`. Each row is one manifest entry, its Monty target
  path, and a progress bar fed by PubSub from the download process.

  The page never blocks: a download is a supervised process, and the row simply
  reflects the last progress it broadcast.
  """

  use ExTbpMontyWeb, :live_view

  alias Monty.Prerequisites
  alias Monty.Prerequisites.Download

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Download.topic())

    prerequisites = Prerequisites.all()

    {:ok,
     assign(socket,
       prerequisites: prerequisites,
       statuses: Map.new(prerequisites, &{&1.id, nil}),
       present: Map.new(prerequisites, &{&1.id, Prerequisites.present?(&1)})
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="mx-auto max-w-4xl space-y-6">
        <header class="space-y-2">
          <h1 class="text-3xl font-semibold tracking-tight">Prerequisites</h1>
          <p class="text-base-content/70">
            Datasets and models an experiment needs, written to the paths Monty's own
            environment variables point at. Downloads stream to <code>.part</code> files
            and move into place only when they are complete.
          </p>
        </header>

        <div class="space-y-3">
          <article
            :for={prerequisite <- @prerequisites}
            id={"prereq-#{prerequisite.id}"}
            class="rounded-box border border-base-300 bg-base-100 p-4"
          >
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div class="space-y-1">
                <h2 class="font-semibold">{prerequisite.title}</h2>
                <p :if={prerequisite.description} class="text-sm text-base-content/70">
                  {prerequisite.description}
                </p>
                <p class="font-mono text-xs break-all text-base-content/60">
                  {Prerequisites.target_path(prerequisite)}
                </p>
              </div>

              <div class="flex items-center gap-2">
                <span class={[
                  "badge",
                  badge_class(status(@statuses, prerequisite.id), @present[prerequisite.id])
                ]}>
                  {status_label(status(@statuses, prerequisite.id), @present[prerequisite.id])}
                </span>
                <button
                  :if={downloadable?(@statuses, prerequisite.id)}
                  id={"download-#{prerequisite.id}"}
                  phx-click="download"
                  phx-value-id={prerequisite.id}
                  class="btn btn-primary btn-sm"
                >
                  <.icon name="hero-arrow-down-tray-mini" class="size-4" /> Download
                </button>
                <button
                  :if={downloading?(@statuses, prerequisite.id)}
                  id={"cancel-#{prerequisite.id}"}
                  phx-click="cancel"
                  phx-value-id={prerequisite.id}
                  class="btn btn-ghost btn-sm"
                >
                  Cancel
                </button>
              </div>
            </div>

            <div :if={progress(@statuses, prerequisite.id)} class="mt-3 space-y-1">
              <progress
                class="progress progress-primary w-full"
                value={progress(@statuses, prerequisite.id).bytes}
                max={max_bytes(progress(@statuses, prerequisite.id))}
              ></progress>
              <p class="font-mono text-xs text-base-content/60">
                {bytes(progress(@statuses, prerequisite.id).bytes)} / {bytes(
                  progress(@statuses, prerequisite.id).total
                )}
              </p>
            </div>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("download", %{"id" => id}, socket) do
    case Prerequisites.get(id) do
      nil -> {:noreply, put_flash(socket, :error, "Unknown prerequisite #{id}")}
      prerequisite -> start(socket, prerequisite)
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case Download.lookup(id) do
      nil ->
        {:noreply, socket}

      server ->
        Download.cancel(server)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:download, %{id: id} = progress}, socket) do
    {:noreply, assign(socket, statuses: Map.put(socket.assigns.statuses, id, progress))}
  end

  defp start(socket, prerequisite) do
    case Download.start(prerequisite) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, start_error(reason))}

      _started ->
        {:noreply, socket}
    end
  end

  # A download that cannot even make its folder is a permissions problem or a
  # wrong `MONTY_MODELS`; saying which is more useful than a tuple.
  defp start_error({:cannot_create, directory, reason}) do
    "Cannot create #{directory} (#{reason}). Check the folder's permissions, or where " <>
      "MONTY_DATA / MONTY_MODELS / MONTY_LOGS point."
  end

  defp start_error(other), do: "Could not start: #{inspect(other)}"

  defp status(statuses, id), do: statuses |> Map.get(id) |> then(&(&1 && &1.status))
  defp downloading?(statuses, id), do: status(statuses, id) == :downloading
  defp progress(statuses, id), do: Map.get(statuses, id)

  defp downloadable?(statuses, id) do
    status(statuses, id) not in [:downloading, :done]
  end

  defp status_label(nil, true), do: "present"
  defp status_label(nil, false), do: "not downloaded"
  defp status_label(:queued, _present), do: "queued"
  defp status_label(:downloading, _present), do: "downloading"
  defp status_label(:done, _present), do: "done"
  defp status_label(:failed, _present), do: "failed"
  defp status_label(:cancelled, _present), do: "cancelled"

  defp badge_class(nil, true), do: "badge-success"
  defp badge_class(nil, false), do: "badge-ghost"
  defp badge_class(:done, _present), do: "badge-success"
  defp badge_class(:failed, _present), do: "badge-error"
  defp badge_class(:downloading, _present), do: "badge-info"
  defp badge_class(_other, _present), do: "badge-ghost"

  defp max_bytes(%{total: nil, bytes: bytes}), do: max(bytes, 1)
  defp max_bytes(%{total: total}), do: total

  defp bytes(nil), do: "—"
  defp bytes(value) when value < 1024, do: "#{value} B"
  defp bytes(value), do: format_unit(value / 1024, ~w(KB MB GB TB))

  defp format_unit(value, [unit | _rest]) when value < 1024,
    do: "#{Float.round(value * 1.0, 1)} #{unit}"

  defp format_unit(value, [_unit | rest]), do: format_unit(value / 1024, rest)
  defp format_unit(value, []), do: "#{value} B"
end
