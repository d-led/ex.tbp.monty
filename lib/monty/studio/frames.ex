defmodule Monty.Studio.Frames do
  @moduledoc """
  Which sensor frames a step should send to a page, and how often.

  A frame per sensor per timestep is the most expensive thing a run sends: the
  PyView prototype that preceded this one throttled images to 100 ms by default,
  for exactly this reason. So the decision "send this sensor's frame now" is
  made here, once, as a pure function of when each sensor last sent — a page
  keeps the timestamps, this keeps the policy, and a test can check the policy
  without a browser or a clock.

  Sensors are throttled independently: a view finder and a patch sensor should
  not queue behind each other.
  """

  alias Monty.Simulators.Synthetic.Camera

  @default_throttle_ms 100

  @type throttle :: %{optional(String.t()) => integer()}

  @doc "How long between frames for one sensor."
  @spec throttle_ms() :: pos_integer()
  def throttle_ms,
    do: Application.get_env(:ex_tbp_monty, :studio_frame_throttle_ms, @default_throttle_ms)

  @doc "Whether a sensor's frame is due, given when it last sent one."
  @spec due?(throttle(), String.t(), integer(), pos_integer()) :: boolean()
  def due?(sent, sensor_id, now_ms, throttle_ms) do
    case Map.get(sent, sensor_id) do
      nil -> true
      last -> now_ms - last >= throttle_ms
    end
  end

  @doc """
  Frames for a step, for the sensors that are due.

  `now_ms` is passed in rather than read here: the caller owns the clock, which
  is what keeps this testable. A sensor with no observation this step gets no
  frame — a stale picture is worse than none.
  """
  @spec for_step([String.t()], map(), non_neg_integer(), throttle(), integer(), pos_integer()) ::
          {[Camera.frame()], throttle()}
  def for_step(sensor_ids, observations, step, sent, now_ms, throttle_ms) do
    observations = Map.get(observations, agent_id(), observations)

    due =
      Enum.filter(sensor_ids, fn sensor_id ->
        Map.has_key?(observations, sensor_id) and due?(sent, sensor_id, now_ms, throttle_ms)
      end)

    frames =
      Enum.map(due, fn sensor_id -> Camera.frame(sensor_id, observations[sensor_id], step) end)

    {frames, Enum.reduce(due, sent, fn sensor_id, sent -> Map.put(sent, sensor_id, now_ms) end)}
  end

  defp agent_id, do: Monty.Simulators.Synthetic.Environment.agent_id()
end
