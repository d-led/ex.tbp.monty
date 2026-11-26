defmodule Monty.Frameworks.Models.Salience.SensorModule.SalienceSM do
  @moduledoc """
  A wide view that proposes where to look next.

  Mirrors `tbp/monty/frameworks/models/salience/sensor_module.py::SalienceSM`,
  the sensor module five of Monty's configs give their view finder. It is not a
  camera: it makes no percept, and what it produces is *goals* for the motor
  system — one per pixel that is on an object, scored by how interesting that
  pixel is — together with the region it would attend to.

  A step is three judgements in a row:

    * the salience strategy scores every pixel of the view (`Uniform`, Monty's
      default, scores them all alike, which leaves the rest of the step to
      decide);
    * the return inhibitor suppresses the pixels near where the sensor has
      recently been, so the goals stop pointing at the place already seen;
    * the weighted scores are dithered and rescaled into `[0, 1]`, which is what
      a goal's confidence means.

  A step the motor system took by itself proposes nothing and changes nothing:
  the sensor did not look, so it has seen nowhere it wants to go — and the goal
  it proposed last step is still where it wanted to go.

  ## The dither

  Monty draws it from the runtime's one `rng`; here it comes from the episode's
  one stream (`Monty.Random.Stream`, reached as `ctx.rng`), in the same order and
  from the same NumPy state, so a salience module dithers its scores with the
  numbers Monty's would (`docs/monty-differences.md` §2.1).

  ## What is not here

  A region is only proposed when the config gives a `segmentation_strategy`, and
  Monty's own — SLIC with merging — is still to come. A module without one
  proposes goals and no region, which is what Monty's does too.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

  alias Monty.Cmp.{AttentionRegion, Goal}
  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.Frameworks.Models.Salience.OnObjectObservation
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor
  alias Monty.Frameworks.Models.Salience.Segmentation.SlicMerge
  alias Monty.Frameworks.Models.Salience.Strategies.Uniform
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.{
    ColorChannelSalience,
    DepthSalience,
    NoOperatingLimits,
    OrientationSalience,
    SafeOperatingLimits,
    Vocus2SalienceConfig
  }

  alias Monty.Frameworks.Models.Salience.Telemetry.NoopSalienceSMTelemetry
  alias Monty.Random.Stream
  # Monty's two factors, as its private methods write them: a visit takes three
  # quarters of a pixel's salience away, and the dither is a twentieth.
  @decay_factor 0.75
  @randomness_factor 0.05

  # `np.isclose(scale, 0)`: every score is the same, so there is no range to
  # rescale — and a range that small is a rounding error, not a difference.
  @flat_range 1.0e-8

  @enforce_keys [:sensor_module_id]
  defstruct sensor_module_id: nil,
            salience_strategy: nil,
            return_inhibitor: nil,
            segmentation_strategy: nil,
            telemetry: nil,
            pose: nil,
            goals: [],
            region: nil

  @typedoc "A module and the state it was given: a strategy, a recorder, an inhibitor."
  @type layer :: {module(), struct()}

  @type t :: %__MODULE__{
          sensor_module_id: atom() | String.t(),
          salience_strategy: layer(),
          return_inhibitor: layer(),
          segmentation_strategy: layer() | nil,
          telemetry: layer(),
          pose: term(),
          goals: [Goal.t()],
          region: AttentionRegion.t() | nil
        }

  @doc """
  A salience module for one sensor.

  Options are Monty's, each a module and its config: `:salience_strategy`
  (default `Strategies.Uniform`), `:return_inhibitor` (default
  `ReturnInhibitor`), `:telemetry` (default `Telemetry.NoopSalienceSMTelemetry`)
  and `:segmentation_strategy` (default none).
  """
  @spec new(atom() | String.t(), keyword()) :: t()
  def new(sensor_module_id, options \\ []) do
    %__MODULE__{
      sensor_module_id: sensor_module_id,
      salience_strategy:
        Keyword.get_lazy(options, :salience_strategy, fn -> {Uniform, Uniform.new()} end),
      return_inhibitor:
        Keyword.get_lazy(options, :return_inhibitor, fn ->
          {ReturnInhibitor, ReturnInhibitor.new()}
        end),
      segmentation_strategy: Keyword.get(options, :segmentation_strategy),
      telemetry:
        Keyword.get_lazy(options, :telemetry, fn ->
          {NoopSalienceSMTelemetry, NoopSalienceSMTelemetry.new()}
        end)
    }
  end

  @target "tbp.monty.frameworks.models.salience.sensor_module.SalienceSM"

  # A VOCUS2 strategy, in the two shapes Monty's own sensor configs write it: as a
  # factory that takes the numbers (`from_config`), and as the class with its
  # three channels written out.
  @vocus2 "tbp.monty.frameworks.models.salience.strategies.vocus2.Vocus2"
  @vocus2_from_config "tbp.monty.frameworks.models.salience.strategies.vocus2.Vocus2.from_config"
  @vocus2_config "tbp.monty.frameworks.models.salience.strategies.vocus2.Vocus2SalienceConfig"
  @color_channel "tbp.monty.frameworks.models.salience.strategies.vocus2.ColorChannelSalience"
  @depth_salience "tbp.monty.frameworks.models.salience.strategies.vocus2.DepthSalience"

  @orientation_salience "tbp.monty.frameworks.models.salience.strategies.vocus2.OrientationSalience"

  # The numbers a centre-surround channel is built from: the sigmas of the two
  # blurs, and how many scales and octaves of them to keep.
  @channel_keys ["center_sigma", "surround_sigma", "n_scales", "max_octaves"]

  @slic_merge "tbp.monty.frameworks.models.salience.segmentation.slic_merge.SlicMerge"

  # The seven numbers `SlicMerge` takes, and the key each is written under.
  @slic_merge_keys [
    "n_seeds",
    "compactness",
    "max_iter",
    "sigma",
    "min_size_factor",
    "max_size_factor",
    "merge_threshold"
  ]

  # This port's addition, and not Monty's: his `SalienceSM` says nothing about
  # drawing from the episode's stream, because Python steps the sensors one after
  # another (`docs/monty-differences.md` §2.28). The dither is drawn from that
  # stream on every informative step, so this sensor is never stepped beside its
  # siblings: its numbers are the order the draws were taken in, and that order
  # is Monty's serial round.
  @impl true
  def draws_from_stream?(_state), do: true

  @doc """
  The salience module a config entry describes, or why it is not this class's.

  Monty's entry names the sensor and, when an experiment wants more than the
  defaults, a `salience_strategy`, a `return_inhibitor`, a `snapshot_telemetry`
  or a `segmentation_strategy`. Every shipped config takes the defaults for all
  four, and a strategy this port has not written is an error rather than a
  silently uniform view.

  `:has_detailed_logger` arrives because every sensor class is asked the same
  question; this one keeps no percept history, so it has nothing to decide.
  """
  @spec from_config(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_config(%{} = config, _options \\ []) do
    with :ok <- check_target(Map.get(config, "_target_", @target)),
         {:ok, sensor_module_id} <- sensor_module_id(config),
         {:ok, strategy} <- layer(config, "salience_strategy", Uniform),
         {:ok, inhibitor} <- layer(config, "return_inhibitor", ReturnInhibitor),
         {:ok, telemetry} <- layer(config, "snapshot_telemetry", NoopSalienceSMTelemetry),
         {:ok, segmentation} <- layer(config, "segmentation_strategy", nil) do
      {:ok,
       new(sensor_module_id,
         salience_strategy: strategy,
         return_inhibitor: inhibitor,
         telemetry: telemetry,
         segmentation_strategy: segmentation
       )}
    end
  end

  defp check_target(@target), do: :ok
  defp check_target(target), do: {:error, {:unsupported_sensor_module, target}}

  defp sensor_module_id(%{"sensor_module_id" => sensor_module_id}), do: {:ok, sensor_module_id}
  defp sensor_module_id(_config), do: {:error, :sensor_module_id_missing}

  defp layer(config, key, default) do
    case Map.get(config, key) do
      nil -> {:ok, default && {default, default.new()}}
      %{"_target_" => target} when target == @target -> {:ok, {default, default.new()}}
      %{"_target_" => target} = spec -> built(key, target, spec)
    end
  end

  # Only the classes this port has written can be built; a config that names
  # another says so by failing to build, and `Setup` refuses the experiment.
  defp built(key, target, spec) do
    case target do
      "tbp.monty.frameworks.models.salience.strategies.uniform.Uniform" ->
        {:ok, {Uniform, Uniform.new()}}

      "tbp.monty.frameworks.models.salience.return_inhibitor.ReturnInhibitor" ->
        {:ok, {ReturnInhibitor, ReturnInhibitor.new()}}

      "tbp.monty.frameworks.models.salience.telemetry.NoopSalienceSMTelemetry" ->
        {:ok, {NoopSalienceSMTelemetry, NoopSalienceSMTelemetry.new()}}

      @vocus2_from_config ->
        vocus2(spec)

      @vocus2 ->
        vocus2_written_out(spec)

      @slic_merge ->
        slic_merge(spec)

      _unsupported ->
        {:error, {:unsupported_layer, key, target}}
    end
  end

  # `SlicMerge` takes seven numbers, and the cows configs state none of them —
  # `new/1`'s defaults are Monty's, which is what the class's own `__init__`
  # declares. A key this port would drop is refused rather than ignored.
  defp slic_merge(spec) do
    with :ok <- reads_only(spec, @slic_merge_keys) do
      {:ok,
       {SlicMerge,
        SlicMerge.new(
          for key <- @slic_merge_keys,
              is_number(Map.get(spec, key)),
              do: {String.to_existing_atom(key), Map.get(spec, key)}
        )}}
    end
  end

  # A VOCUS2 config names `Vocus2.from_config` rather than the class, because the
  # class takes three built channel processors and no experiment writes those out;
  # the numbers come from a `Vocus2SalienceConfig` beneath `config:`.
  defp vocus2(%{"config" => %{"_target_" => @vocus2_config} = config}) do
    {:ok,
     {Vocus2,
      Vocus2.from_config(
        Vocus2SalienceConfig.new(
          center_sigma: Map.get(config, "center_sigma", 3.0),
          surround_sigma: Map.get(config, "surround_sigma", 5.0),
          n_scales: Map.get(config, "n_scales", 2),
          max_octaves: Map.get(config, "max_octaves", 5),
          use_depth: Map.get(config, "use_depth", true),
          use_orientation: Map.get(config, "use_orientation", true)
        )
      )}}
  end

  defp vocus2(spec) do
    {:error, {:unsupported_layer, "salience_strategy", Map.get(spec, "config")}}
  end

  # The other shape Monty's sensor configs use: the class with its arguments
  # written out, which is Hydra instantiating `Vocus2.__init__` one parameter at a
  # time. `color` is the one it requires; `depth` and `orientation` are `null`
  # when the strategy is colour-only, which is how the cows family's view finder
  # is configured.
  defp vocus2_written_out(%{"color" => color} = spec) do
    with :ok <- reads_only(spec, ["color", "depth", "orientation"]),
         {:ok, color} <- color_channel(color),
         {:ok, depth} <- salience_channel(spec["depth"], @depth_salience, &depth_salience/1),
         {:ok, orientation} <-
           salience_channel(spec["orientation"], @orientation_salience, &orientation_salience/1) do
      {:ok, {Vocus2, Vocus2.new(color: color, depth: depth, orientation: orientation)}}
    end
  end

  defp vocus2_written_out(_spec) do
    {:error, {:unsupported_layer, "salience_strategy.color", nil}}
  end

  # `Vocus2.__init__` also names a `color_space_converter`, a `combine` and a
  # `normalize`, and no config states any of them — so the defaults are Monty's.
  # One that did would be refused rather than dropped, because a different
  # combination or rescale is a different salience map under the same config's
  # name.
  defp reads_only(spec, keys) do
    case Map.keys(spec) -- ["_target_" | keys] do
      [] -> :ok
      [key | _unread] -> {:error, {:argument_not_read, key}}
    end
  end

  defp color_channel(%{"_target_" => @color_channel} = spec) do
    with :ok <- reads_only(spec, ["operating_limits" | @channel_keys]),
         {:ok, limits} <- operating_limits(spec["operating_limits"]) do
      options = numbers(spec, @channel_keys)

      {:ok,
       ColorChannelSalience.new(
         if(limits, do: options ++ [operating_limits: limits], else: options)
       )}
    end
  end

  defp color_channel(%{"_target_" => target}), do: {:error, {:unsupported_layer, "color", target}}

  defp depth_salience(%{"_target_" => @depth_salience} = spec) do
    with :ok <- reads_only(spec, @channel_keys) do
      {:ok, DepthSalience.new(numbers(spec, @channel_keys))}
    end
  end

  # A period is the one argument its own constructor requires; `sigma` defaults
  # to `0.3 * period` inside it, which is Monty's rule.
  defp orientation_salience(%{"_target_" => @orientation_salience} = spec) do
    with :ok <- reads_only(spec, ["period", "sigma", "phase", "gamma", "n_orientations"]) do
      {:ok,
       OrientationSalience.new(
         numbers(spec, ["period", "sigma", "phase", "gamma", "n_orientations"])
       )}
    end
  end

  defp salience_channel(nil, _target, _build), do: {:ok, nil}

  defp salience_channel(%{"_target_" => target} = spec, target, build), do: build.(spec)

  defp salience_channel(%{"_target_" => target}, _expected, _build),
    do: {:error, {:unsupported_layer, "channel", target}}

  defp operating_limits(nil), do: {:ok, nil}

  defp operating_limits(%{"_target_" => target}) do
    case target do
      "tbp.monty.frameworks.models.salience.strategies.vocus2.NoOperatingLimits" ->
        {:ok, NoOperatingLimits.new()}

      "tbp.monty.frameworks.models.salience.strategies.vocus2.SafeOperatingLimits" ->
        {:ok, SafeOperatingLimits.new()}

      _unsupported ->
        {:error, {:unsupported_layer, "operating_limits", target}}
    end
  end

  # Only the keys the config states, because a keyword list carrying `nil` would
  # overwrite a default with nothing.
  defp numbers(spec, keys) do
    for key <- keys, is_number(Map.get(spec, key)), do: {String.to_existing_atom(key), spec[key]}
  end

  @impl true
  def update_state(%AgentState{} = agent, %__MODULE__{} = sm) do
    %__MODULE__{sm | pose: AgentState.sensor_pose(agent, sm.sensor_module_id)}
  end

  @impl true
  def step(_observation, true, _ctx, %__MODULE__{} = sm) do
    # The sensor did not look, so it has nothing to score and nothing to
    # withdraw (`sensor_module.py:112-114`).
    {nil, sm}
  end

  def step(observation, false, ctx, %__MODULE__{} = sm) do
    salience_map = score(sm, ctx, observation)
    view = OnObjectObservation.from(observation, salience_map)
    {inhibition, inhibitor} = return_inhibitor(sm, view.centre_location, view.locations)
    salience = weight_salience(ctx, sm.sensor_module_id, view.salience, inhibition)
    goals = goals_for(sm, view.locations, salience)
    {region, segmentation, segmentation_map} = segment_region(sm, ctx, observation, view)

    telemetry =
      sm.telemetry
      |> record_raw(observation, sm.pose)
      |> record_salience(salience_map)
      |> record_goals(goals)
      |> record_segmentation(segmentation_map, region)

    {nil,
     %__MODULE__{
       sm
       | return_inhibitor: inhibitor,
         segmentation_strategy: segmentation,
         telemetry: telemetry,
         goals: goals,
         region: region
     }}
  end

  @impl true
  def propose_goals(%__MODULE__{} = sm), do: {sm.goals, sm}

  @impl true
  def propose_region(%__MODULE__{region: nil} = sm), do: {AttentionRegion.empty(), sm}
  def propose_region(%__MODULE__{region: region} = sm), do: {region, sm}

  @doc "What the strategy scored, the segmentation proposed and the goals say."
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{telemetry: {module, telemetry}}), do: module.state_dict(telemetry)

  @impl true
  def reset(%__MODULE__{} = sm) do
    {inhibitor_module, inhibitor} = sm.return_inhibitor
    {telemetry_module, telemetry} = sm.telemetry

    %__MODULE__{
      sm
      | goals: [],
        region: nil,
        return_inhibitor: {inhibitor_module, inhibitor_module.reset(inhibitor)},
        telemetry: {telemetry_module, telemetry_module.reset(telemetry)}
    }
  end

  # -- the three judgements --------------------------------------------------

  defp score(%__MODULE__{salience_strategy: {module, strategy}}, ctx, observation) do
    module.call(strategy, ctx, Map.fetch!(observation, "rgba"), Map.fetch!(observation, "depth"))
  end

  # The inhibitor ages on every call, so it answers the one the next step uses —
  # kept as the module-and-state pair it was stored as.
  defp return_inhibitor(%__MODULE__{return_inhibitor: {module, inhibitor}}, centre, locations) do
    {weights, inhibitor} = module.call(inhibitor, centre, locations)
    {weights, {module, inhibitor}}
  end

  # A visit takes three quarters of a pixel's salience away; the dither moves the
  # result by a twentieth of a unit; and what is left is rescaled into `[0, 1]`,
  # which is the range a goal's confidence may carry.
  defp weight_salience(ctx, sensor_module_id, salience, inhibition) do
    salience
    |> Enum.zip_with(inhibition, fn score, weight -> score - @decay_factor * weight end)
    |> dither(ctx, sensor_module_id)
    |> normalize()
  end

  defp dither([], _ctx, _id), do: []

  # One draw per score, from the episode's stream — `ctx.rng.normal(loc=0,
  # scale=0.05, size=...)` — and the order it draws in decides which region the
  # agent turns towards, so the stream has to be Monty's (`Monty.Random.Stream`).
  defp dither(scores, ctx, _sensor_module_id) do
    noise = Stream.normals(ctx.rng, length(scores), 0.0, @randomness_factor)

    Enum.zip_with([scores, noise], fn [score, amount] -> score + amount end)
  end

  defp normalize([]), do: []

  defp normalize(scores) do
    {lowest, highest} = Enum.min_max(scores)
    scale = highest - lowest

    if scale < @flat_range,
      do: Enum.map(scores, fn score -> score |> max(0.0) |> min(1.0) end),
      else: Enum.map(scores, fn score -> (score - lowest) / scale end)
  end

  # One goal per on-object pixel: the motor system may look at it, and the
  # learning modules must not learn from it — a salience module says where, not
  # what. A goal is built as its struct rather than through `Goal.new/1`: its
  # fields are this module's own — the place is a point of the view, three
  # numbers by the walk that collected it, and the confidence is the rescale
  # above, which cannot leave `[0, 1]` — and `SalienceSMTest` holds those two
  # facts at the output. A view carries a goal per on-object pixel, so a call
  # and a validation per goal was most of a salience step.
  defp goals_for(%__MODULE__{} = sm, locations, salience) do
    Enum.zip_with([locations, salience], fn [location, confidence] ->
      %Goal{
        location: location,
        confidence: confidence,
        pass_message: false,
        process_features_in_lm: false,
        sender_id: to_string(sm.sensor_module_id),
        sender_type: :sm
      }
    end)
  end

  # A segmentation is optional: without one the module says where to look and not
  # how much of the surface to attend to, which is what Monty's does without a
  # strategy too.
  defp segment_region(%__MODULE__{segmentation_strategy: nil}, _ctx, _observation, _view),
    do: {AttentionRegion.empty(), nil, nil}

  defp segment_region(
         %__MODULE__{segmentation_strategy: {module, strategy}},
         ctx,
         observation,
         view
       ) do
    {segmentation_map, strategy} = module.call(strategy, ctx, colour(observation))

    region =
      view
      |> region_locations(segmentation_map)
      |> then(&AttentionRegion.uniform(&1, AttentionRegion.max_weight()))

    {region, {module, strategy}, segmentation_map}
  end

  # The pixels both segmented and on the object, as locations: a region is about
  # the surface under the view, not about everything the segmenter saw.
  # Three planes walked together, by pattern: `Enum.zip/2` over three-element
  # tuples is the Stream machinery, and this runs once for every pixel of the
  # view.
  defp region_locations(%OnObjectObservation{} = view, segmentation_map) do
    view.location_map
    |> gathered(view.on_object_map, segmentation_map, [])
    |> Enum.reverse()
  end

  defp gathered([], _mask, _segments, acc), do: acc

  defp gathered([locations | locationss], [mask | masks], [segments | segmentss], acc) do
    gathered(locationss, masks, segmentss, row(locations, mask, segments, acc))
  end

  defp row([], _mask, _segments, acc), do: acc

  defp row([location | locations], [true | mask], [segment | segments], acc)
       when segment != 0,
       do: row(locations, mask, segments, [location | acc])

  defp row([_location | locations], [_on_object | mask], [_segment | segments], acc),
    do: row(locations, mask, segments, acc)

  # -- recording -------------------------------------------------------------

  defp record_raw({module, telemetry}, observation, %{rotation: rotation, position: position}),
    do: {module, module.raw_observation(telemetry, observation, rotation, position)}

  defp record_salience({module, telemetry}, salience_map),
    do: {module, module.salience_map(telemetry, salience_map)}

  defp record_goals({module, telemetry}, goals), do: {module, module.goals(telemetry, goals)}

  defp record_segmentation({module, telemetry}, nil, _region), do: {module, telemetry}

  defp record_segmentation({module, telemetry}, segmentation_map, region) do
    telemetry =
      telemetry
      |> then(&module.segmentation_map(&1, segmentation_map))
      |> then(&module.attention_region(&1, region))

    {module, telemetry}
  end

  defp colour(observation) do
    observation
    |> Map.fetch!("rgba")
    |> Enum.map(fn row -> Enum.map(row, fn pixel -> Enum.take(pixel, 3) end) end)
  end
end
