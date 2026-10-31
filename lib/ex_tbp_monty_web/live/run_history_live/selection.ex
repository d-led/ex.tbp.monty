defmodule ExTbpMontyWeb.RunHistoryLive.Selection do
  @moduledoc """
  Which runs are picked out of the list, and what deleting them would mean.

  Picking a row, picking the page, and asking the question before it happens are
  one small piece of state: a set of ids. Keeping it here rather than in the
  page's event handlers means the rules — picking all takes the page, the page
  only, and picking all again gives it back — are functions with names, and the
  page has nothing to do but assign what they answer.
  """

  @typedoc "The ids of the runs a person has picked."
  @type picked :: MapSet.t(binary())

  @typedoc """
  What a confirmation is about: the runs picked, or every run the filter shows.

  The filter is kept whole — state and text — because deleting "all of them" is
  a statement about the list on screen, which is the filter, not the page of it.
  """
  @type scope :: {:ids, [binary()]} | {:matching, keyword()}

  @type question :: %{count: non_neg_integer(), scope: scope()}

  @doc "The events this module answers, so the page can hand them all over at once."
  @spec events() :: [String.t()]
  def events do
    ~w(toggle toggle_all clear_selection ask_delete_selected ask_delete_matching cancel_bulk_delete bulk_delete)
  end

  @doc """
  What an event does.

  Answers `{:assign, assigns}` for the events that only move the selection, and
  `{:forget, scope}` for the one that deletes, which is the page's to carry out.
  """
  @spec handle(String.t(), map(), map()) :: {:assign, keyword()} | {:forget, scope()}
  def handle("toggle", %{"id" => id}, %{selected: selected}),
    do: {:assign, selected: toggle(selected, id)}

  def handle("toggle_all", _params, %{selected: selected, page_ids: page}),
    do: {:assign, selected: toggle_page(selected, page)}

  def handle("clear_selection", _params, _assigns), do: {:assign, selected: MapSet.new()}

  def handle("ask_delete_selected", _params, %{selected: selected}),
    do: {:assign, confirming_bulk: picked_question(selected)}

  def handle("ask_delete_matching", _params, %{state: state, text: text, total: total}),
    do: {:assign, confirming_bulk: shown_question(state, text, total)}

  def handle("cancel_bulk_delete", _params, _assigns), do: {:assign, confirming_bulk: nil}

  def handle("bulk_delete", _params, %{confirming_bulk: %{scope: scope}}),
    do: {:forget, scope}

  defp toggle(picked, id) do
    if MapSet.member?(picked, id), do: MapSet.delete(picked, id), else: MapSet.put(picked, id)
  end

  # A page that is entirely picked is let go again by the same click; one that is
  # only partly picked is taken. Runs picked on another page are none of this
  # page's business and stay picked.
  defp toggle_page(picked, page) do
    if Enum.all?(page, &MapSet.member?(picked, &1)) do
      Enum.reduce(page, picked, &MapSet.delete(&2, &1))
    else
      Enum.reduce(page, picked, &MapSet.put(&2, &1))
    end
  end

  defp picked_question(picked) do
    %{count: MapSet.size(picked), scope: {:ids, MapSet.to_list(picked)}}
  end

  defp shown_question(state, text, total) do
    %{count: total, scope: {:matching, [state: state, text: text]}}
  end
end
