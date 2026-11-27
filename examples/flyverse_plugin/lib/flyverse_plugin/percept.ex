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

  ## Two channels, because a fly has no depth image

  A depth image is a rendering this port can afford; a compound eye is what a
  fly has. The colours of the same view are here too — `luminance/3` reads the
  `rgba` the sensor recorded and answers one number per pixel — so a policy can
  be driven by what a photoreceptor could see and not only by a distance the
  animal never measures. What a photoreceptor answers is *change*: a surface that
  approaches grows in the field of view and the band it grows in brightens or
  darkens, and the polarity is not something a loom detector gets to choose. That
  is `luminance_bands/2` and the policy's `sensor: :rgba`.

  ## The nearest thing, not the average of the frame

  A side's nearness is the closest thing on it, not the mean over its pixels. A
  wide view is mostly room: averaging `1 / depth` across it answers the distance
  to the walls, and a mug half a metre away on one side of the frame moves that
  average by almost nothing — which is why an approach driven by the mean is a
  lazy arc that takes a hundred and fifty steps. What a fly turns toward is what
  looms. Beyond `@horizon` metres a pixel is landscape and not a destination: the
  far wall of this world is 799 m away, and `1/799` is noise dressed as a drive.

  ## Which half is which

  A band is a run of columns, and two of them are the left half of the image and
  the right half of it, with an odd middle column going to the right. That is a
  statement about how the image is stored, not about a fly's eyes: a real
  binocular channel would be built from the retinotopy.

  ## How many bands

  `bands/2` asks the same question of any number of columns-runs, because that is
  where a connectome's input comes from: a pack names as many drive groups as its
  sensory groups have, and a pack that names one index per group gets one rate
  per index. Two is what the four-neuron demonstrator's plan asks for and what
  `nearness/1` answers; a pack built from the dataset's sensory inventory would
  ask for hundreds, which is the shape the retina is in and the shape this
  function can already drive.
  """

  # The sensors Monty's own configs name, in the order an agent's view is worth
  # trying them: the wide one first, because the patch is small by design.
  @preferred ["view_finder", "patch"]

  # Beyond this, a depth pixel is landscape rather than a thing to walk to.
  @horizon 10.0

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
    case Map.fetch(observations || %{}, agent_id) do
      {:ok, agent} when is_map(agent) ->
        candidates = @preferred ++ (Map.keys(agent) -- @preferred)

        Enum.find_value(candidates, no_image(agent_id), fn sensor_id ->
          case depth(observations, agent_id, sensor_id) do
            {:ok, rows} -> {:ok, {sensor_id, rows}}
            {:error, _sentence} -> nil
          end
        end)

      _no_agent ->
        no_image(agent_id)
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
  How close the nearest thing is on the left half and on the right half.

  Two rates in inverse metres: `0.0` for a side that saw nothing within the
  horizon at all. The two-band case of `bands/2`.
  """
  @spec nearness([[number()]]) :: {float(), float()}
  def nearness(rows) do
    [left, right] = bands(rows, 2)
    {left, right}
  end

  @doc """
  How close the nearest thing is in each of `count` bands of the image.

  A band is a run of columns — the image's width divided into `count` parts, the
  last one taking the remainder — and its nearness is the nearest thing in it,
  the same question `nearness/1` asks of a half. `count` is the number of drive
  groups the pack's plan names, so a network with two groups is driven by the
  two halves of the view and a network with a group per sensory column is driven
  by a column per group.
  """
  @spec bands([[number()]], pos_integer()) :: [float()]
  def bands(rows, count) when is_integer(count) and count > 0 do
    width = rows |> hd() |> length()

    for index <- 0..(count - 1) do
      first = div(width * index, count)
      last = div(width * (index + 1), count) - 1

      if last < first, do: 0.0, else: nearest_in(rows, first, last)
    end
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

  defp nearest_in(rows, first, last) do
    rows
    |> Enum.flat_map(fn row -> row |> Enum.slice(first..last//1) |> Enum.map(&nearness_of/1) end)
    |> Enum.reject(&(&1 == 0.0))
    |> case do
      [] -> 0.0
      values -> Enum.max(values)
    end
  end

  @doc """
  The same bands, as the light each one returns.

  `luminance/3`'s rows are floats in `0..1`, so a band's answer is their mean: how
  much light that part of the view returned. It is not a distance and must not be
  read as one — what a photoreceptor band is *for* is the difference between one
  step and the next.
  """
  @spec luminance_bands([[number()]], pos_integer()) :: [float()]
  def luminance_bands(rows, count) when is_integer(count) and count > 0 do
    width = rows |> hd() |> length()

    for index <- 0..(count - 1) do
      first = div(width * index, count)
      last = div(width * (index + 1), count) - 1

      if last < first, do: 0.0, else: mean_in(rows, first, last)
    end
  end

  @doc """
  What each band changed by since the last step, in the units a rate is built from.

  A photoreceptor reports light, so the only thing a band of them can tell a
  network is how much that band *changed*: a surface that approaches grows in the
  field of view, and the band it grows in brightens or darkens. The polarity is not
  a loom detector's to choose — a growing dark shape looms as much as a growing
  light one — so the change is taken as a magnitude, and `gain` is what makes it
  comparable with a distance: a band that swung the whole of its range is driven as
  hard as a surface at the near limit.

  `nil` is a first step, which has nothing to be a change of, and answers zeros.
  """
  @spec loom([number()] | nil, [number()] | nil, number()) :: [float()]
  def loom(bands, nil, _gain), do: List.duplicate(0.0, length(bands))

  def loom(bands, previous, gain) do
    bands
    |> Enum.zip(previous)
    |> Enum.map(fn {now, was} -> abs(now - was) * gain end)
  end

  @doc """
  The colours the sensor recorded, as one luminance per pixel in `0..1`.

  Rec. 709's weights, because a camera's green is most of what a fly's eye would
  have too. `{:ok, {sensor_id, rows}}` with the same sensor chosen as `image/3`,
  or a sentence naming what is missing — a policy asked for the photoreceptor
  channel by a world that renders no colours must be refused rather than driven
  by nothing.
  """
  @spec luminance(map() | nil, String.t(), String.t() | nil) ::
          {:ok, {String.t(), [[float()]]}} | {:error, String.t()}
  def luminance(observations, agent_id, sensor_id), do: colours(observations, agent_id, sensor_id)

  defp colours(observations, agent_id, sensor_id) when is_binary(sensor_id) do
    with {:ok, rows} <- rgba(observations, agent_id, sensor_id),
         do: {:ok, {sensor_id, rows}}
  end

  defp colours(observations, agent_id, nil) do
    case Map.fetch(observations || %{}, agent_id) do
      {:ok, agent} when is_map(agent) ->
        candidates = @preferred ++ (Map.keys(agent) -- @preferred)

        Enum.find_value(candidates, no_colours(agent_id), fn sensor_id ->
          case rgba(observations, agent_id, sensor_id) do
            {:ok, rows} -> {:ok, {sensor_id, rows}}
            {:error, _sentence} -> nil
          end
        end)

      _no_agent ->
        no_colours(agent_id)
    end
  end

  defp rgba(observations, agent_id, sensor_id) do
    with {:ok, agent} when is_map(agent) <- Map.fetch(observations || %{}, agent_id),
         {:ok, sensor} when is_map(sensor) <- Map.fetch(agent, sensor_id),
         {:ok, image} when is_list(image) and image != [] <- Map.fetch(sensor, "rgba"),
         true <- Enum.all?(image, &(is_list(&1) and &1 != [])) do
      {:ok, Enum.map(image, fn row -> Enum.map(row, &luma/1) end)}
    else
      {:ok, _not_an_image} -> {:error, "the #{sensor_id} of #{agent_id} recorded no colours"}
      _missing -> {:error, "the #{sensor_id} of #{agent_id} recorded no colours this step"}
    end
  end

  # `0..255` channels, as `[r, g, b, a]`, to one number in `0..1`. A channel that
  # arrived as a float is taken at its word; anything that is not a channel is
  # black, which is what an unrendered pixel is.
  defp luma([red, green, blue | _alpha]) do
    (0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)) / 255.0
  end

  defp luma(_not_a_pixel), do: 0.0

  defp channel(value) when is_number(value) and value <= 1.0 and value >= 0.0, do: value * 255.0
  defp channel(value) when is_number(value), do: value / 1.0
  defp channel(_not_a_channel), do: 0.0

  defp mean_in(rows, first, last) do
    values =
      rows
      |> Enum.flat_map(fn row -> Enum.slice(row, first..last//1) end)
      |> Enum.filter(&is_number/1)

    case values do
      [] -> 0.0
      values -> Enum.sum(values) / length(values)
    end
  end

  defp no_colours(agent_id) do
    {:error,
     "none of #{agent_id}'s sensors recorded colours this step, and the photoreceptor " <>
       "channel needs them"}
  end

  defp nearness_of(depth) when is_number(depth) and depth > 0 and depth <= @horizon,
    do: 1.0 / depth

  defp nearness_of(_nothing_or_invalid_or_far), do: 0.0
end
