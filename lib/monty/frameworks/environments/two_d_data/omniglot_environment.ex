defmodule Monty.Frameworks.Environments.TwoDData.OmniglotEnvironment do
  @moduledoc """
  A world that is a drawing, and a pen that follows the path that drew it.

  Mirrors `tbp/monty/frameworks/environments/two_d_data.py::OmniglotEnvironment`.
  Omniglot is 1623 handwritten characters from 50 alphabets, each drawn 20 times,
  and the dataset keeps the *order the pen moved* as a list of points. Monty's
  world uses that list instead of a motor policy: an action does not steer the
  sensor anywhere, it steps along the strokes by the number of points the action
  asks for, and past the end of the path it starts again — so a character is
  traced a stroke at a time and a patch is a piece of it.

  Two things are worth knowing before reading the arithmetic:

    * A drawing is one bit a pixel, and this port's decoder writes that out as
      eight (0 or 255), so `true` — Monty's `np.array(img, dtype=bool)` — is the
      paper and `false` is the ink. Everything below is in the inverted picture:
      the ink is where the object is.
    * Depth is not measured, it is *made*: `1.2 - gaussian_filter(~patch)`, so the
      ink sits at 0.2 m, the paper at 1.2 m, and the patch's edges are smoothed by
      half a pixel of Gaussian rather than being a hard step. A surface agent then
      has a surface with a normal at every stroke, which is what the tutorial is
      about.

  Monty's own numbers are kept: the patch is 10 pixels square, the character is
  shown upright, and the whole drawing is the view finder's picture.
  """

  @behaviour Monty.Simulators.Environment

  alias Monty.Frameworks.Environments.TwoDData
  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.Frameworks.Models.MotorSystemState.SensorState
  alias Monty.Geometry.Rotation

  # Letters are always presented upright, in the port's own axis-angle form.
  @upright :math.pi() / 2.0
  # What the ink is: a stroke is 0.2 m away and the paper behind it 1.2 m.
  @far 1.2
  @sigma 0.5
  @default_patch_size 10
  @agent_id "agent_id_0"
  @patch "patch"
  @view_finder "view_finder"

  @enforce_keys [:data_path, :alphabet_names]
  defstruct patch_size: @default_patch_size,
            data_path: nil,
            alphabet_names: [],
            alphabet: nil,
            character_id: 1,
            character_version: 1,
            image: nil,
            locations: [],
            max_steps: 0,
            step_num: 0

  @type t :: %__MODULE__{
          patch_size: pos_integer(),
          data_path: Path.t(),
          alphabet_names: [String.t()],
          alphabet: String.t() | nil,
          character_id: pos_integer(),
          character_version: pos_integer(),
          image: TwoDData.drawing() | nil,
          locations: [[float()]],
          max_steps: non_neg_integer(),
          step_num: non_neg_integer()
        }

  @doc """
  The world over the drawings in a dataset, started on the first character.

  Options: `:data_path` (the dataset's `python/` directory, holding
  `images_background/` and `strokes_background/`; absent means Monty's own place
  for it) and `:patch_size`.

  A directory holding no alphabet is refused: a world with nothing to draw would
  run an episode and show the model an empty page for however many steps the
  config asks for.
  """
  @impl true
  @spec new(keyword() | Path.t()) :: t()
  def new(data_path) when is_binary(data_path), do: new(data_path: data_path)

  def new(options) do
    path = options |> Keyword.get(:data_path) |> dataset_path()
    {alphabet, alphabet_names} = path |> alphabet_names() |> alphabets_or_refuse(path)

    %__MODULE__{
      data_path: path,
      alphabet_names: alphabet_names,
      alphabet: alphabet,
      patch_size: patch_size(options)
    }
    |> load_new_character_data()
  end

  @spec patch_size(keyword()) :: pos_integer()
  defp patch_size(options) do
    case Keyword.get(options, :patch_size) do
      nil -> @default_patch_size
      size when is_integer(size) and size > 0 -> size
    end
  end

  # Monty's `monty_data_path(data_path, "omniglot/python")`: the config may name
  # the directory, and one that names none is asked for the archive's place under
  # this application's data directory.
  @doc """
  Which directory a config's drawings are read from.

  `nil` is Monty's own place for them — `MONTY_DATA/omniglot/python`, which this
  application reads as `data/omniglot/python` under its own directory.
  """
  @spec dataset_path(Path.t() | nil) :: Path.t()
  def dataset_path(nil), do: Path.join([Monty.Paths.data(), "omniglot", "python"])
  def dataset_path(path), do: Path.expand(path)

  @doc """
  The dataset's alphabets, as their directory names in the order it sorts them.

  Empty when the directory is not there, which is how a config whose data has not
  been downloaded is found out.
  """
  @spec alphabet_names(Path.t()) :: [String.t()]
  def alphabet_names(data_path) do
    case File.ls(Path.join(data_path, "images_background")) do
      {:ok, names} -> names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      {:error, _missing} -> []
    end
  end

  # A world with nothing to draw would run an episode and show the model an empty
  # page for however many steps the config asks for.
  @spec alphabets_or_refuse([String.t()], Path.t()) :: {String.t(), [String.t()]}
  defp alphabets_or_refuse([first | _] = names, _data_path), do: {first, names}

  defp alphabets_or_refuse([], data_path) do
    raise ArgumentError,
          "#{data_path} holds no alphabet: an Omniglot world needs the dataset's " <>
            "images_background/ (one directory per alphabet) and strokes_background/ " <>
            "beside it"
  end

  @doc """
  The next observation, after `actions` have moved along the pen's path.

  Monty's step is the path's, not the action's: an action only says *how far* —
  `rotation_degrees` points, and at least one — and the sensor reads the path's
  point at that count, wrapping at the end of it.
  """
  @impl true
  def step(%__MODULE__{} = environment, actions) do
    environment =
      Enum.reduce(actions, environment, fn action, environment ->
        %{environment | step_num: environment.step_num + amount(action)}
      end)

    {observations(environment), state(environment), environment}
  end

  defp amount(action) do
    case rotation_degrees(action) do
      nil -> 1
      degrees -> degrees |> max(1) |> trunc()
    end
  end

  defp rotation_degrees(%{rotation_degrees: degrees}) when is_number(degrees), do: degrees
  defp rotation_degrees(%{"rotation_degrees" => degrees}) when is_number(degrees), do: degrees
  defp rotation_degrees(_action), do: nil

  @doc """
  The world a fresh episode starts in: the same character, from its first point.
  """
  @impl true
  def reset(%__MODULE__{} = environment), do: %{environment | step_num: 0}

  @doc """
  Loads the character an episode is about.

  Monty addresses it by three numbers: which alphabet, which character in it, and
  which of the 20 drawings of that character. The pen's path is then filtered to
  the points a patch fits at, because a patch taken half off the picture is not a
  patch of the character.
  """
  @spec switch_to_object(t(), non_neg_integer(), pos_integer(), pos_integer()) :: t()
  def switch_to_object(%__MODULE__{} = environment, alphabet_id, character_id, version_id) do
    %__MODULE__{
      environment
      | alphabet: Enum.at(environment.alphabet_names, alphabet_id),
        character_id: character_id,
        character_version: version_id
    }
    |> load_new_character_data()
  end

  @doc """
  The character's drawing, and where a patch may be taken along it.

  Monty finds the character's number from a file name in its directory — every
  file there is named for the character and the version, `0709_01.png` — and then
  builds the version's own names from it.
  """
  @spec load_new_character_data(t()) :: t()
  def load_new_character_data(%__MODULE__{} = environment) do
    stem = character_file(environment)

    image =
      TwoDData.load_img(
        Path.join(character_directory(environment, "images_background"), stem <> ".png")
      )

    strokes =
      environment
      |> character_directory("strokes_background")
      |> Path.join(stem <> ".txt")
      |> TwoDData.load_motor()

    locations = strokes |> motor_to_locations() |> fit_patches(image, environment.patch_size)

    if length(locations) < 2 do
      raise ArgumentError,
            "#{environment.alphabet} character #{environment.character_id} version " <>
              "#{environment.character_version} has #{length(locations)} point(s) a " <>
              "#{environment.patch_size}-pixel patch fits at, so there is no path to walk: " <>
              "Monty divides by that count, and a character that is all border is not one " <>
              "to trace"
    end

    %__MODULE__{
      environment
      | image: image,
        locations: locations,
        max_steps: length(locations) - 1
    }
  end

  defp character_directory(environment, root) do
    Path.join([
      environment.data_path,
      root,
      environment.alphabet,
      "character#{String.pad_leading(to_string(environment.character_id), 2, "0")}"
    ])
  end

  # The character's own number, read off a file in its directory and paired with
  # the version the episode asked for: `0709_01.png` is the character `0709`, drawn
  # the first time. Monty reads the number from the first entry its directory
  # yields; this reads it from the first in sorted order, which is the same number
  # because every file in the directory carries it.
  defp character_file(environment) do
    number =
      environment
      |> character_directory("images_background")
      |> File.ls!()
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.sort()
      |> List.first()
      |> String.split("_")
      |> List.first()

    "#{number}_#{String.pad_leading(to_string(environment.character_version), 2, "0")}"
  end

  @doc """
  The pen's path as image positions: every stroke's `x` and `y`, `y` flipped.

  Monty stacks the strokes into one path, in the order they were drawn, and drops
  the `time` the dataset keeps as a third column.
  """
  @spec motor_to_locations([TwoDData.stroke()]) :: [[float()]]
  def motor_to_locations(strokes) do
    stones = Enum.map(strokes, fn stroke -> Enum.map(stroke, &Enum.take(&1, 2)) end)

    stones
    |> Enum.map(&TwoDData.space_motor_to_img/1)
    |> Enum.concat()
  end

  # A patch is `patch_size` square, so a point nearer the border than that leaves
  # half a patch outside the picture. Monty keeps the points that are more than a
  # patch in and less than the picture's edge less a patch, on both axes.
  defp fit_patches(locations, image, size) do
    edge = length(image) - size

    Enum.filter(locations, fn [y, x] -> y > size and x > size and y < edge and x < edge end)
  end

  @doc """
  The patch a sensor sees at the path's current point: the ink, as depth.

  Monty's `get_image_patch(self.current_image, query_loc, self.patch_size)`, which
  is a picture's slice `img[startx:stopx, starty:stopy]` with the axes Monty
  crosses there — the patch's rows are the position's `x` and its columns the
  position's `y`.
  """
  @spec get_image_patch(t(), [float()]) :: TwoDData.drawing()
  def get_image_patch(%__MODULE__{} = environment, [y, x]) do
    half = div(environment.patch_size, 2)
    rows = trunc(x) - half
    columns = trunc(y) - half

    for row <- rows..(rows + environment.patch_size - 1) do
      Enum.slice(Enum.at(environment.image, row), columns..(columns + environment.patch_size - 1))
    end
  end

  @doc """
  What the sensors see at the path's current point.

  The patch's depth is the ink smoothed and moved to 0.2 m, its semantic map is
  the ink itself (1 on the stroke, 0 on the paper), and its colour is that depth
  in three channels. The view finder is the whole drawing.

  Monty's view finder answers the *patch's* semantic map beside the whole picture's
  depth, which is his line rather than a choice here, and it is kept: a sensor that
  reads semantic ids in this world reads the patch it was given.
  """
  @spec observations(t()) :: map()
  def observations(%__MODULE__{} = environment) do
    patch = get_image_patch(environment, query_loc(environment))
    ink = Enum.map(patch, fn row -> Enum.map(row, &(not &1)) end)
    depth = ink |> smoothed() |> Enum.map(fn row -> Enum.map(row, &(@far - &1)) end)
    semantic = Enum.map(ink, fn row -> Enum.map(row, &if(&1, do: 1, else: 0)) end)

    %{
      @agent_id => %{
        @patch => %{
          "depth" => depth,
          "semantic" => semantic,
          "rgba" => Enum.map(depth, fn row -> Enum.map(row, &[&1, &1, &1]) end)
        },
        @view_finder => %{
          "depth" => environment.image,
          "semantic" => semantic
        }
      }
    }
  end

  # `1.2 - gaussian_filter(np.array(~patch, dtype=float), sigma=0.5)`: the ink as
  # ones, smoothed, and read as a distance from a wall 1.2 m away.
  defp smoothed(ink) do
    ink
    |> Enum.map(fn row -> Enum.map(row, &if(&1, do: 1.0, else: 0.0)) end)
    |> gaussian_filter(@sigma)
  end

  @doc """
  `scipy.ndimage.gaussian_filter` of a picture, with the sigma Monty passes.

  A separable Gaussian of radius `int(4σ + 0.5)` pixels, normalised to one, and
  the picture reflected at its edges (the edge pixel repeated) — scipy's default
  `mode="reflect"`, which is what a Gaussian over a 10-pixel patch needs: a patch
  is a window onto a character, and the ink just outside it is as real as the ink
  inside.

  This is a different Gaussian from the one `GetGoodView` runs over an on-object
  mask (zero padding, `docs/monty-differences.md` §1.15); the two differ because
  Monty's two calls differ.
  """
  @spec gaussian_filter([[float()]], float()) :: [[float()]]
  def gaussian_filter(rows, sigma) when sigma > 0 do
    weights = weights(sigma)

    rows
    |> Enum.map(&correlate(&1, weights))
    |> transpose()
    |> Enum.map(&correlate(&1, weights))
    |> transpose()
  end

  def gaussian_filter(rows, _sigma), do: rows

  # scipy truncates the kernel at four sigma, and rounds to the nearest pixel.
  defp weights(sigma) do
    radius = trunc(4.0 * sigma + 0.5)
    sampled = for offset <- -radius..radius, do: :math.exp(-0.5 * :math.pow(offset / sigma, 2))
    total = Enum.sum(sampled)

    Enum.map(sampled, &(&1 / total))
  end

  defp correlate(values, weights) do
    size = length(values)
    radius = div(length(weights) - 1, 2)

    for position <- 0..(size - 1) do
      weights
      |> Enum.with_index(-radius)
      |> Enum.reduce(0.0, fn {weight, offset}, sum ->
        sum + weight * Enum.at(values, reflected(position + offset, size))
      end)
    end
  end

  # scipy's `reflect`: the picture mirrored about its edge pixel, which is the one
  # that is repeated.
  defp reflected(position, size) do
    folded = Integer.mod(position, 2 * size)
    if folded >= size, do: 2 * size - 1 - folded, else: folded
  end

  defp transpose([]), do: []
  defp transpose(rows), do: rows |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

  @doc """
  Where the sensors are: the path's current point, in the picture's plane.

  The pen moves in two dimensions and the picture is upright, so the position is
  the point with no height, and both sensors sit on it with the same rotation.
  """
  @spec state(t()) :: map()
  def state(%__MODULE__{} = environment) do
    [y, x] = query_loc(environment)
    position = [y, x, 0.0]
    {:ok, rotation} = Rotation.from_axis_angle([1.0, 0.0, 0.0], @upright)
    sensor = %SensorState{position: position, rotation: rotation}

    %{
      @agent_id => %AgentState{
        sensors: %{@patch => sensor, @view_finder => sensor},
        position: [0.0, 0.0, 0.0],
        rotation: rotation
      }
    }
  end

  # `self.locations[self.step_num % self.max_steps]`: the path is walked and then
  # walked again, and the last point is where an episode stops rather than a place
  # a step reads.
  defp query_loc(%__MODULE__{} = environment),
    do: Enum.at(environment.locations, rem(environment.step_num, environment.max_steps))

  @impl true
  def stop(%__MODULE__{}), do: :ok

  @impl true
  def positions_itself?, do: false

  @doc """
  What a character is called: its alphabet's directory and its number.

  Monty's interface names it `self.env.alphabet_names[alphabets[i]] + "_" +
  str(characters[i])`, so the name says both what it is and where it came from.
  """
  @spec character_name(String.t() | nil, pos_integer()) :: String.t()
  def character_name(alphabet, character_id), do: "#{alphabet}_#{character_id}"

  @doc """
  The character this world is showing, as Monty's `PrimaryTarget`.

  A supervised episode is told the ground truth just before its memory is
  updated, and the world is what knows it: the config named the character and this
  is the one loaded. A drawing lies flat and upright at the origin, so the target
  has no position, rotation or scale of its own — Monty's own values for this
  dataset.
  """
  @impl true
  @spec primary_target(t()) :: map() | nil
  def primary_target(%__MODULE__{alphabet: alphabet, character_id: character_id})
      when is_binary(alphabet) do
    %{
      "object_name" => character_name(alphabet, character_id),
      "euler_rotation" => [0.0, 0.0, 0.0],
      "position" => [0.0, 0.0, 0.0],
      # Monty's `PrimaryTarget` carries the turn under both names: `rotation`,
      # which is the `wxyz` quaternion, and `quat_rotation`, which is the one a
      # rotation is built from. Not turned is the identity.
      "rotation" => [1.0, 0.0, 0.0, 0.0],
      "quat_rotation" => [1.0, 0.0, 0.0, 0.0],
      "scale" => [1.0, 1.0, 1.0]
    }
  end

  def primary_target(%__MODULE__{}), do: nil
end
