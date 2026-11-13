defmodule FlyversePlugin.Percept do
  @moduledoc """
  What the sensor saw, in the two numbers this plugin's network is driven by.

  The one honest thing a *policy* can take from an observation without deciding
  the answer itself is a drive: the world on the left of the view and the world
  on the right of it. Turning that into an action is the network's job, which is
  the point of the example — a policy that computed "steer away from the wall"
  in Elixir would be a policy, and the connectome would be decoration.

  ## Nearness, not depth

  A depth image answers metres, and a metre is not a rate. `1 / depth` is: it is
  what an optic-flow or loom channel measures, and it gives a number that grows
  as a surface approaches without a distance at which the model has to be told
  that it is close. A cell that reports no depth (zero or negative, which is how
  an unrendered pixel arrives) contributes nothing rather than an infinite
  closeness.

  ## Which half is which

  The image is split at its middle column, and an odd column goes to the right
  half. That is a statement about how the image is stored, not about a fly's
  eyes: a real binocular channel would be built from the retinotopy, and this
  plugin's packs are not a fly.
  """

  # The sensors Monty's own configs name, in the order an agent's view is worth
  # trying them: the wide one first, because the patch is small by design.
  @preferred ["view_finder", "patch"]

  @doc """
  The depth image to drive from, and which sensor it came from.

  A named sensor is used as named. `nil` asks for the one Monty's own configs
  put in front of an agent — `view_finder`, then `patch` — and falls back to any
  sensor of the agent that recorded a depth image at all, so a config this
  plugin has never seen still has a chance to be driven instead of refused.
  """
  @spec image(map() | nil, String.t(), String.t() | nil) ::
          {:ok, {String.t(), [[number()]]}} | {:error, String.t()}
  def image(observations, agent_id, sensor_id) when is_binary(sensor_id) do
    with {:ok, rows} <- depth(observations, agent_id, sensor_id),
         do: {:ok, {sensor_id, rows}}
  end

  def image(observations, agent_id, nil) do
    with {:ok, agent} when is_map(agent) <- Map.fetch(observations || %{}, agent_id) do
      candidates = @preferred ++ (Map.keys(agent) -- @preferred)

      Enum.find_value(candidates, no_image(agent_id), fn sensor_id ->
        case depth(observations, agent_id, sensor_id) do
          {:ok, rows} -> {:ok, {sensor_id, rows}}
          {:error, _sentence} -> nil
        end
      end)
    else
      _no_agent -> no_image(agent_id)
    end
  end

  @doc """
  The depth rows of `sensor_id` as Monty recorded them.

  `{:ok, rows}` or a sentence naming what is missing — a policy that answered an
  action anyway would be deciding with no percept and not saying so.
  """
  @spec depth(map() | nil, String.t(), String.t()) ::
          {:ok, [[number()]]} | {:error, String.t()}
  def depth(nil, _agent_id, sensor_id) do
    {:error, "this step carried no observations, so there is nothing from #{sensor_id}"}
  end

  def depth(observations, agent_id, sensor_id) do
    with {:ok, agent} when is_map(agent) <- Map.fetch(observations, agent_id),
         {:ok, sensor} when is_map(sensor) <- Map.fetch(agent, sensor_id),
         {:ok, depth} <- Map.fetch(sensor, "depth"),
         :ok <- image(depth, sensor_id) do
      {:ok, depth}
    else
      :error ->
        {:error,
         "the observations of #{agent_id} carry no depth for #{sensor_id}; the policy is " <>
           "driven by an image and cannot be driven by nothing"}

      {:error, sentence} ->
        {:error, sentence}
    end
  end

  @doc """
  How close the world is on the left half and on the right half of the image.

  Two rates in inverse metres: `0.0` for a side that saw nothing at all.
  """
  @spec nearness([[number()]]) :: {float(), float()}
  def nearness(rows) do
    {left, right} = Enum.unzip(Enum.map(rows, &Enum.split(&1, div(length(&1), 2))))

    {mean_nearness(left), mean_nearness(right)}
  end

  defp no_image(agent_id) do
    {:error,
     "none of #{agent_id}'s sensors recorded a depth image this step, so there is nothing to " <>
       "drive the network with"}
  end

  defp image(rows, _sensor_id) when is_list(rows) and rows != [] do
    if Enum.all?(rows, &is_list/1), do: :ok, else: not_an_image()
  end

  defp image(_rows, _sensor_id), do: not_an_image()

  defp not_an_image do
    {:error, "a depth image is a list of rows, and this is not one"}
  end

  defp mean_nearness(rows) do
    values = Enum.flat_map(rows, fn row -> Enum.map(row, &nearness_of/1) end)

    case values do
      [] -> 0.0
      values -> Enum.sum(values) / length(values)
    end
  end

  defp nearness_of(depth) when is_number(depth) and depth > 0, do: 1.0 / depth
  defp nearness_of(_nothing_or_invalid), do: 0.0
end
