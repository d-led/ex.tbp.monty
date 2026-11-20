defmodule Monty.Random.NumpyTest do
  use ExUnit.Case, async: true

  alias Monty.Random.Numpy

  # An episode's seed from Monty's own `eval_stats.csv` — the first episode of
  # `base_config_10distinctobj_dist_agent`.
  @episode_seed 1_170_100_843

  # Every number in this file was printed by numpy 1.23.5 in Monty's own
  # environment. They are the specification: a generator that agrees with NumPy on
  # these agrees with it on what Monty draws, and one that does not is a different
  # experiment however plausible its statistics look.
  defmodule Fixtures do
    @moduledoc false

    def samples, do: [0.20329638816634776, 0.29085086873618826, 0.5237705430136725]
    def more_samples, do: [0.2641547205501692, 0.5900611060504631]

    def uniform_degrees, do: [-106.8133002601148, -75.29368725497223, 8.557395484922125]

    def normals, do: [-0.03260111614826397, -0.046248668844803296, -0.08595771088332692]

    def later_normals, do: [0.00866356735515495, -0.007990449831047498]

    def standard_normals, do: [-0.6520223229652794, -0.9249733768960658, -1.7191542176665382]

    def spare_normal, do: 0.173271347103099

    # `RandomState(1170100843).normal(0.0, [0.1, 0.2, 0.2], 3)`.
    def scaled_normals, do: [-0.06520223229652793, -0.18499467537921313, -0.3438308435333077]

    # The one action sampler's draw, over four actions, and the same over three
    # and over seven — ranges that are not powers of two, where numpy masks a word
    # and redraws while it is past the range.
    def choices_of_four, do: [3, 2, 1, 3, 1, 3, 1, 1]
    def choices_of_three, do: [2, 1, 1, 1, 1, 2, 1, 1]
    def choices_of_seven, do: [2, 5, 1, 1, 5, 2]

    # `randint(10, 20, 8)`, and `choice(4)` four times after one `random_sample`
    # — which is what says the draws share one stream in numpy's order.
    def randints_ten_to_twenty, do: [17, 12, 15, 11, 17, 19, 15, 12]
    def choices_after_a_sample, do: [1, 3, 1, 3]
  end

  describe "new/1" do
    # `RandomState(42).get_state()[1][:4]`, which is the seeded array itself.
    test "seeds the Mersenne Twister as NumPy seeds it" do
      state = Numpy.new(42)

      assert Tuple.to_list(state.key) |> Enum.take(4) == [
               42,
               3_107_752_595,
               1_895_908_407,
               3_900_362_577
             ]

      assert tuple_size(state.key) == 624
    end

    test "refuses a seed that is not one word, because NumPy would not seed it either" do
      assert_raise FunctionClauseError, fn -> Numpy.new(4_294_967_296) end
    end
  end

  describe "random_sample/1" do
    test "is NumPy's first draws" do
      {draws, _state} = draw(5, &Numpy.random_sample/1)

      assert draws ==
               Fixtures.samples() ++ Fixtures.more_samples()
    end

    test "gives the same numbers again from the same seed, which is the whole point" do
      {first, _state} = draw(5, &Numpy.random_sample/1)
      {second, _state} = draw(5, &Numpy.random_sample/1)

      assert first == second
    end
  end

  describe "uniform/3" do
    test "spreads NumPy's draw across the interval" do
      {draws, _state} = draw(3, &Numpy.uniform(&1, -180.0, 180.0))

      assert draws == Fixtures.uniform_degrees()
    end
  end

  describe "randint/3 and choice/2" do
    # The action sampler's draw: `rng.choice(self._method_names)` in Monty's
    # `action_samplers.py`. A run's walk is what this decides, so these are the
    # numbers that make a run Monty's run rather than a different walk of the same
    # world.
    test "is NumPy's choice, over actions and over a range that is not a power of two" do
      {of_four, _state} = draw(8, &Numpy.choice(&1, 4))
      {of_three, _state} = draw(8, &Numpy.choice(&1, 3))
      {of_seven, _state} = draw(6, &Numpy.choice(&1, 7))

      assert of_four == Fixtures.choices_of_four()
      assert of_three == Fixtures.choices_of_three()
      assert of_seven == Fixtures.choices_of_seven()
    end

    test "is NumPy's randint, offset by the bottom of the range" do
      {draws, _state} = draw(8, &Numpy.randint(&1, 10, 20))

      assert draws == Fixtures.randints_ten_to_twenty()
    end

    test "spends one draw of the same stream, in the order it was asked" do
      {_sample, state} = Numpy.random_sample(Numpy.new(@episode_seed))

      {draws, _state} =
        Enum.map_reduce(1..4, state, fn _draw, state -> Numpy.choice(state, 4) end)

      assert draws == Fixtures.choices_after_a_sample()
    end
  end

  describe "normal/3" do
    test "is NumPy's normals, scaled by the standard deviation" do
      {draws, _state} = draw(3, &Numpy.normal(&1, 0.0, 0.05))

      assert draws == Fixtures.normals()
    end

    test "keeps NumPy's spare draw, so what follows is its next normal and not another pair" do
      {first, state} = Numpy.normals(Numpy.new(@episode_seed), 3, 0.0, 0.05)
      {rest, _state} = Numpy.normals(state, 2, 0.0, 0.05)

      assert first == Fixtures.normals()
      assert rest == Fixtures.later_normals()
    end

    test "hands its spare to the next call, as NumPy does across an odd length" do
      {odd, state} = Numpy.normals(Numpy.new(@episode_seed), 3, 0.0, 1.0)
      {spare, _state} = Numpy.normal(state, 0.0, 1.0)

      assert odd == Fixtures.standard_normals()
      assert spare == Fixtures.spare_normal()
    end

    test "scales a draw at a time when it is given a scale a draw" do
      # Monty writes a per-channel noise amount as an array
      # (`noise_params.features.hsv: [0.1, 0.2, 0.2]`), and NumPy broadcasts it
      # over the draws. The numbers are numpy 1.23.5's own: its array path sums
      # `loc + scale * z` a shade differently from scaling the standard draws
      # here, so the last digits are compared to 1e-12 rather than to equality.
      {draws, state} = Numpy.normals(Numpy.new(@episode_seed), 3, 0.0, [0.1, 0.2, 0.2])

      assert Enum.zip(draws, Fixtures.scaled_normals())
             |> Enum.all?(fn {ours, numpy} -> abs(ours - numpy) < 1.0e-12 end)

      # The same normals the scalar calls spend, so what follows is unchanged.
      {spare, _state} = Numpy.normal(state, 0.0, 1.0)

      assert spare == Fixtures.spare_normal()
    end

    test "refuses a scale a draw that does not fit the draws, as NumPy would" do
      assert_raise ArgumentError, ~r/one scale to one draw/, fn ->
        Numpy.normals(Numpy.new(@episode_seed), 3, 0.0, [0.1, 0.2])
      end
    end
  end

  defp draw(count, draw) do
    Enum.map_reduce(1..count, Numpy.new(@episode_seed), fn _draw, state -> draw.(state) end)
  end
end
