defmodule Monty.Frameworks.Utils.SpatialArithmetics do
  @moduledoc """
  Vector and rotation arithmetic on pose vectors.

  Mirrors `tbp/monty/frameworks/utils/spatial_arithmetics.py`. Everything here
  answers one of two questions: *how far apart are these directions*, or *what
  does this rotation do to these directions*.

  ## What a pose is

  A pose vector set is three row vectors — the surface normal and the two
  principal curvature directions — held as a 3×3 list of lists, in Monty's
  `[normal, curvature_1, curvature_2]` order. Features carry the same thing
  flattened to nine numbers, so the batch helpers take rows of nine.

  ## Two divergences from the Python, both deliberate

    * **Quaternions are rotations.** Python returns `[x, y, z, w]` arrays from
      scipy's `as_quat()`, while Monty's own `QuaternionWXYZ` and its configs
      write `w` first. Rather than pass an array whose meaning depends on which
      library produced it, the converters return a `Monty.Geometry.Rotation`,
      which has exactly one spelling.
    * **An undefined angle is `:infinity`.** Python returns `np.inf`; there is
      no float infinity in the BEAM, and `:infinity` sorts above every number,
      so `get_angle_beefed_up/2 < tolerance` still reads as false — the answer
      callers want. Trying to do arithmetic on it raises, which is better than
      quietly propagating a NaN.
  """

  alias Monty.Geometry
  alias Monty.Geometry.GazeDirection
  alias Monty.Geometry.Rotation
  alias Monty.Geometry.SurfacePoseVectors
  alias Monty.Math

  @type vector :: [float()]
  @type matrix :: [[float()]]
  @type angle :: float() | :infinity

  @doc """
  A unit vector in the direction of `v`.

  Raises when `v` is shorter than `epsilon`: there is no direction to return for
  the zero vector, and returning zero would put a non-unit vector into a pose
  that later arithmetic assumes is unit.
  """
  @spec normalize([number()], float()) :: vector()
  def normalize([x, y, z] = vector, epsilon \\ Math.default_tolerance()) do
    length = magnitude(vector)

    if length < epsilon do
      raise ArgumentError,
            "cannot normalize #{inspect([x, y, z])}: length #{length} < #{epsilon}"
    end

    [x / length, y / length, z / length]
  end

  @doc """
  The part of `v` lying in the plane with normal `n`.

  `v` minus its projection onto `n`, so a vector parallel to the normal collapses
  to zero and a vector already in the plane is unchanged.
  """
  @spec project_onto_tangent_plane([number()], [number()]) :: vector()
  def project_onto_tangent_plane(vector, normal) do
    unit_normal = normalize(normal)
    subtract(vector, scale(unit_normal, dot(vector, unit_normal)))
  end

  @doc """
  Whether two *unit* vectors point along the same line, in either direction.

  `tolerance` bounds `1 - |cos θ|`, so it reads as "the angle is within
  `sqrt(2 · tolerance)` of 0 or π" — and, unlike comparing a dot product to 1,
  it treats both ends of the line alike.

  Monty calls this `is_parallel`; Elixir reserves the `is_` prefix for guards,
  so the name is the one thing here that changed shape.
  """
  @spec parallel?([number()], [number()], float()) :: boolean()
  def parallel?(v1, v2, tolerance \\ Math.default_tolerance()) do
    1.0 - abs(dot(v1, v2)) < tolerance
  end

  @doc """
  Converts rotations to `Monty.Geometry.Rotation`s.

  Euler angles (a flat three-list) are what the feature LM produces, rotation
  matrices (a list of three rows) what the evidence LM produces; the shape says
  which, exactly as `ndim` does in Python. `invert: true` returns the rotations
  that undo the given ones.
  """
  @spec rotations_to_rotations([vector() | matrix()], keyword()) :: [Rotation.t()]
  def rotations_to_rotations([[_ | _] | _] = rotations, options \\ []) do
    case hd(rotations) do
      [_, _, _] -> euler_to_rotations(rotations, options)
      _matrix -> rotation_matrices_to_rotations(rotations, options)
    end
  end

  @doc "Converts a list of rotation matrices to rotations."
  @spec rotation_matrices_to_rotations([matrix()], keyword()) :: [Rotation.t()]
  def rotation_matrices_to_rotations(rotation_matrices, options \\ []) do
    Enum.map(rotation_matrices, fn matrix ->
      {:ok, rotation} = Rotation.from_matrix(matrix)
      maybe_invert(rotation, Keyword.get(options, :invert, false))
    end)
  end

  @doc "Converts a list of Euler angles, in degrees, to rotations."
  @spec euler_to_rotations([vector()], keyword()) :: [Rotation.t()]
  def euler_to_rotations(euler_rotations, options \\ []) do
    Enum.map(euler_rotations, fn euler ->
      {:ok, rotation} = Rotation.from_euler_degrees(euler)
      maybe_invert(rotation, Keyword.get(options, :invert, false))
    end)
  end

  @doc """
  The angle between two *unit* vectors, in radians.

  Assumes unit input for speed — the surface normals and curvature directions
  this is used on already are. Use `get_angle_between/2` for vectors of any
  length, or `get_angle_beefed_up/2` when either side may be undefined.
  """
  @spec get_angle([number()], [number()]) :: float()
  def get_angle(v1, v2), do: :math.acos(clip(dot(v1, v2), -1.0, 1.0))

  @doc """
  The angle between two vectors, in radians, or `:infinity` when either is
  undefined (not a vector) or has no direction (the zero vector).

  An undefined direction is similar to nothing, which is the point: a hypothesis
  with no curvature direction should be excluded from a comparison, not win it
  by looking maximally unlike its competitors along one particular axis.
  """
  @spec get_angle_beefed_up([number()] | nil, [number()] | nil) :: angle()
  def get_angle_beefed_up([_, _, _] = v1, [_, _, _] = v2) do
    if no_direction?(v1) or no_direction?(v2) do
      :infinity
    else
      get_angle(normalize(v1), normalize(v2))
    end
  end

  def get_angle_beefed_up(_not_a_vector, _not_a_vector_too), do: :infinity

  @doc """
  The angles between each hypothesis' neighbours and its query vector.

  `hypothesis_features` is one list of neighbour vectors per hypothesis,
  `query_features` one vector per hypothesis; the result is one list of angles
  per hypothesis, in the neighbours' order.
  """
  @spec get_angles_for_all_hypotheses([[vector()]], [vector()]) :: [[float()]]
  def get_angles_for_all_hypotheses(hypothesis_features, query_features) do
    Enum.zip_with(hypothesis_features, query_features, fn neighbours, query ->
      Enum.map(neighbours, &get_angle(&1, query))
    end)
  end

  @doc """
  The angle between two vectors of any length, in radians.

  The magnitudes cancel inside `atan2`, so no normalisation is needed. A zero
  vector contains no direction, and 0.0 is the answer Monty documents for it.
  """
  @spec get_angle_between([number()], [number()]) :: float()
  def get_angle_between(v1, v2), do: :math.atan2(magnitude(cross(v1, v2)), dot(v1, v2))

  @doc """
  Whether a matrix is orthonormal: mutually perpendicular unit rows.

  Both halves come from `transpose(m) · m` being the identity — off-diagonal
  entries measure non-perpendicularity, diagonal ones measure row length. Monty
  allows a mean absolute error of 0.01, generous enough to accept a curvature
  estimate that is only roughly orthogonal.
  """
  @spec check_orthonormal(matrix()) :: boolean()
  def check_orthonormal(matrix) do
    gram = Geometry.mul(Geometry.transpose(matrix), matrix)
    mean_absolute_difference(gram, Geometry.identity()) < 0.01
  end

  @doc """
  The rotation that turns the frame `m1` into the frame `m2`, and how badly it
  fails to.

  Rows are vectors, so the alignment rotation is `m1ᵀ · m2` — `m2`'s rows
  expressed in `m1`'s basis. The error is how far applying that rotation's
  inverse to `m1` lands from `m2`: ~0 for a right-handed pair, and large for a
  mirrored one, which is why Monty kept the number around.
  """
  @spec align_orthonormal_vectors(matrix(), matrix()) :: {Rotation.t(), float()}
  def align_orthonormal_vectors(m1, m2) do
    {:ok, rotation} = m1 |> align_orthonormal_vectors_as_matrix(m2) |> Rotation.from_matrix()
    inverse = Rotation.invert(rotation)

    error =
      m1
      |> Enum.map(&Rotation.apply(inverse, &1))
      |> then(&mean_absolute_difference(&1, m2))

    {rotation, error}
  end

  @doc """
  The rotation *matrix* that turns the frame `m1` into the frame `m2`, with no
  rotation object in the way.

  A mirrored pair has no matrix that turns one into the other; the matrix here
  is the reflection itself, which is why `align_orthonormal_vectors/2` measures
  its error against the nearest proper rotation instead.
  """
  @spec align_orthonormal_vectors_as_matrix(matrix(), matrix()) :: matrix()
  def align_orthonormal_vectors_as_matrix(m1, m2) do
    Geometry.mul(Geometry.transpose(m1), m2)
  end

  @doc """
  The matrix that turns each of `frames` into `target`, one per frame.

  Monty asks for these rather than for rotations (`as_scipy=False` in
  `align_multiple_orthonormal_vectors`), and that is the form a learning module
  keeps: a stored node frame is only *approximately* orthonormal — YCB's surface
  normals and curvature directions are unit to a few parts in a thousand and
  perpendicular to a few hundredths — so the product is only approximately a
  rotation. Rounding it to the nearest rotation instead, as a rotation object
  does, moves the pose by hundredths of a radian: the displacement it rotates
  drifts by millimetres a step, and the pose evidence drifts with it.
  """
  @spec align_multiple_orthonormal_vectors_as_matrices([matrix()], matrix()) :: [matrix()]
  def align_multiple_orthonormal_vectors_as_matrices(frames, target) do
    Enum.map(frames, &align_orthonormal_vectors_as_matrix(&1, target))
  end

  @doc """
  The angle from `v1` to `v2`, in radians, signed by `surface_normal`.

  Both directions live in the plane, so the sign is what "clockwise seen from
  the normal" means — the sign is the whole reason to prefer this over
  `get_angle/2`, which cannot tell a turn from its mirror image.
  """
  @spec get_right_hand_angle([number()], [number()], [number()]) :: float()
  def get_right_hand_angle(v1, v2, surface_normal) do
    :math.atan2(dot(cross(v1, v2), surface_normal), dot(v1, v2))
  end

  @doc """
  Whether a matrix can be inverted.

  Monty asks numpy for the condition number — how much an input error can be
  amplified by inverting — and accepts anything below `1/ε`. Without LAPACK the
  estimate here is the 1-norm condition number `‖a‖₁ · ‖a⁻¹‖₁`, a small factor
  away from numpy's 2-norm figure and sharing the property that matters: a
  singular matrix has no inverse, so both are infinite.
  """
  @spec non_singular_mat(matrix()) :: boolean()
  def non_singular_mat(matrix) do
    case inverse(matrix) do
      :singular -> false
      inverse -> norm_1(matrix) * norm_1(inverse) < 1.0 / machine_epsilon()
    end
  end

  @doc """
  Unit vectors evenly spaced in the plane orthogonal to `frame`'s first vector.

  `frame` holds the normal and the two curvature directions; `count` directions
  are sampled by turning the first curvature direction towards the second. This
  is how a flat surface, whose curvature directions are arbitrary, still offers
  Monty a spread of candidate poses.
  """
  @spec get_more_directions_in_plane(matrix(), pos_integer()) :: [matrix()]
  def get_more_directions_in_plane([normal, first, second], count) do
    Enum.map(0..(count - 1)//1, fn index ->
      angle = 2 * :math.pi() * index / count
      direction = add(scale(first, :math.cos(angle)), scale(second, :math.sin(angle)))
      [normal, direction, cross(normal, direction)]
    end)
  end

  @doc """
  The distinct rotations among `poses`, as `{euler_poses, rotations}`.

  `poses` is a list of paths, each a list of rotations; a rotation is kept the
  first time it appears within `similarity_th` radians of everything kept so
  far. The Euler angles come back rounded to 3 decimals and wrapped into
  `[0, 360)`, because they are used as human-readable labels.

  `:reverse?` (default `true`) returns the rotations that undo each kept pose,
  matching Monty's default.
  """
  @spec get_unique_rotations([[Rotation.t()]], float(), keyword()) ::
          {[vector()], [Rotation.t()]}
  def get_unique_rotations(poses, similarity_th, options \\ []) do
    reverse? = Keyword.get(options, :reverse?, true)

    {euler_poses, rotations, _kept} =
      poses
      |> List.flatten()
      |> Enum.reduce({[], [], []}, fn pose, {eulers, rotations, kept} ->
        if pose_is_new(kept, pose, similarity_th) do
          chosen = if reverse?, do: Rotation.invert(pose), else: pose
          euler = chosen |> Rotation.to_euler_degrees() |> Enum.map(&wrap_degrees/1)

          {[euler | eulers], [chosen | rotations], [pose | kept]}
        else
          {eulers, rotations, kept}
        end
      end)

    {Enum.reverse(euler_poses), Enum.reverse(rotations)}
  end

  @doc """
  Whether `new_pose` differs from every pose in `all_poses` by at least
  `similarity_th` radians.
  """
  @spec pose_is_new([Rotation.t()], Rotation.t(), float()) :: boolean()
  def pose_is_new(all_poses, new_pose, similarity_th) do
    Enum.all?(all_poses, fn pose ->
      new_pose
      |> Rotation.multiply(Rotation.invert(pose))
      |> Rotation.magnitude()
      |> Kernel.>=(similarity_th)
    end)
  end

  @doc """
  Applies each of `rotations` to the same pose vector set.

  Returns one rotated 3×3 set per rotation, in the rotations' order.
  """
  @spec batch_rotate_pose_vectors(SurfacePoseVectors.t(), [matrix()]) :: [matrix()]
  def batch_rotate_pose_vectors(%SurfacePoseVectors{value: value}, rotations) do
    # Rows are vectors, so a rotation applied on the left needs the transpose:
    # `value · Rᵀ`, which is `(R · valueᵀ)ᵀ`.
    Enum.map(rotations, &Geometry.mul(value, Geometry.transpose(&1)))
  end

  @doc """
  Rotates a pose vector set by one rotation.

  A gaze direction is where to look, not a surface frame, so rotating it is
  meaningless; it raises rather than returning something that looks like a pose.
  """
  @spec rotate_pose_vectors(SurfacePoseVectors.t() | GazeDirection.t(), Rotation.t()) ::
          SurfacePoseVectors.t()
  def rotate_pose_vectors(%SurfacePoseVectors{value: value} = pose_vectors, rotation) do
    %SurfacePoseVectors{pose_vectors | value: Rotation.apply(rotation, value)}
  end

  def rotate_pose_vectors(%GazeDirection{}, _rotation) do
    raise ArgumentError, "GazeDirection is not supported for rotation"
  end

  @doc """
  Rotates rows of flattened pose vectors — nine numbers, three vectors each.

  The rows keep their order and their length; only the directions change.
  """
  @spec rotate_multiple_pose_vectors([vector()], Rotation.t()) :: [vector()]
  def rotate_multiple_pose_vectors(pose_vectors, rotation) do
    Enum.map(pose_vectors, fn row ->
      row
      |> Enum.chunk_every(3)
      |> then(&Rotation.apply(rotation, &1))
      |> List.flatten()
    end)
  end

  @doc """
  Transforms observed points into the model's reference frame.

  `locations` are sensor positions in the body frame, `features` the features
  observed there. The two reference points — where that spot sits in the model
  and where it sits in the body — are the same physical point seen twice, so
  centring on one, rotating, and shifting to the other is the whole transform.
  `object_rotation` expresses how the model must be rotated to match the
  observations, hence its inverse here.

  `object_scale` is accepted and ignored, as in Monty.
  """
  @spec apply_rf_transform_to_points(
          [vector()],
          %{required(String.t()) => term()},
          vector(),
          vector(),
          Rotation.t(),
          number()
        ) :: {[vector()], %{required(String.t()) => term()}}
  def apply_rf_transform_to_points(
        locations,
        features,
        location_rel_model,
        object_location_rel_body,
        object_rotation,
        object_scale \\ 1
      ) do
    _ = object_scale
    inverse = Rotation.invert(object_rotation)

    transformed_locations =
      locations
      |> Enum.map(&subtract(&1, object_location_rel_body))
      |> then(&Rotation.apply(inverse, &1))
      |> Enum.map(&add(&1, location_rel_model))

    features = Map.update!(features, "pose_vectors", &rotate_multiple_pose_vectors(&1, inverse))

    {transformed_locations, features}
  end

  @doc "The length of a 3-vector."
  @spec magnitude([number()]) :: float()
  def magnitude([x, y, z]), do: :math.sqrt(x * x + y * y + z * z)

  @doc "The dot product of two 3-vectors."
  @spec dot([number()], [number()]) :: number()
  def dot([a1, a2, a3], [b1, b2, b3]), do: a1 * b1 + a2 * b2 + a3 * b3

  @doc "The cross product of two 3-vectors."
  @spec cross([number()], [number()]) :: vector()
  def cross([a1, a2, a3], [b1, b2, b3]) do
    [a2 * b3 - a3 * b2, a3 * b1 - a1 * b3, a1 * b2 - a2 * b1]
  end

  @doc "Adds two 3-vectors."
  @spec add([number()], [number()]) :: vector()
  def add([a1, a2, a3], [b1, b2, b3]), do: [a1 + b1, a2 + b2, a3 + b3]

  @doc "Subtracts two 3-vectors."
  @spec subtract([number()], [number()]) :: vector()
  def subtract([a1, a2, a3], [b1, b2, b3]), do: [a1 - b1, a2 - b2, a3 - b3]

  @doc "Multiplies a 3-vector by a scalar."
  @spec scale([number()], number()) :: vector()
  def scale([x, y, z], factor), do: [x * factor, y * factor, z * factor]

  @doc """
  The inverse of a 3×3 matrix, or `:singular` when it has none.

  Cofactor expansion, which in three dimensions is both exact and shorter than
  any iterative method.
  """
  @spec inverse(matrix()) :: matrix() | :singular
  def inverse([[a, b, c], [d, e, f], [g, h, i]]) do
    determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)

    if abs(determinant) < machine_epsilon() * 1.0e4 do
      :singular
    else
      [
        [e * i - f * h, c * h - b * i, b * f - c * e],
        [f * g - d * i, a * i - c * g, c * d - a * f],
        [d * h - e * g, b * g - a * h, a * e - b * d]
      ]
      |> Enum.map(fn row -> Enum.map(row, &(&1 / determinant)) end)
    end
  end

  @doc "The 1-norm of a matrix: its largest absolute column sum."
  @spec norm_1(matrix()) :: float()
  def norm_1(matrix) do
    matrix
    |> Geometry.transpose()
    |> Enum.map(fn column -> column |> Enum.map(&abs/1) |> Enum.sum() end)
    |> Enum.max()
  end

  @doc "The gap between 1.0 and the next float, as `sys.float_info.epsilon`."
  @spec machine_epsilon() :: float()
  def machine_epsilon, do: 2.220446049250313e-16

  defp maybe_invert(rotation, true), do: Rotation.invert(rotation)
  defp maybe_invert(rotation, false), do: rotation

  defp no_direction?(vector), do: magnitude(vector) < Math.default_tolerance()

  defp clip(value, low, high), do: value |> max(low) |> min(high)

  defp wrap_degrees(degrees) do
    wrapped = :math.fmod(degrees + 360.0, 360.0)
    if wrapped >= 360.0, do: wrapped - 360.0, else: wrapped
  end

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp mean_absolute_difference(left, right) do
    left
    |> Enum.zip(right)
    |> Enum.flat_map(fn {left_row, right_row} ->
      Enum.zip_with(left_row, right_row, &abs(&1 - &2))
    end)
    |> mean()
  end
end
