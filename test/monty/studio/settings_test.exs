defmodule Monty.Studio.SettingsTest do
  use ExTbpMonty.DataCase

  alias Monty.Studio.Settings

  describe "a setting nobody has touched" do
    test "is what the application does by default" do
      assert Settings.get("run_refresh_ms") == 250
    end

    test "is offered to a form as the text a browser sends back" do
      assert Settings.form_values() == %{"run_refresh_ms" => "250"}
    end
  end

  describe "saving a setting" do
    test "is what the next read answers" do
      assert {:ok, 500} = Settings.put("run_refresh_ms", "500")

      assert Settings.get("run_refresh_ms") == 500
      assert Settings.values() == %{"run_refresh_ms" => 500}
    end

    test "a number the application cannot live with is refused, with a sentence" do
      assert {:error, message} = Settings.put("run_refresh_ms", "1")

      assert message =~ "Run page refresh has to be between 50 and 10000"
    end

    test "and so is something that is not a number at all" do
      assert {:error, message} = Settings.put("run_refresh_ms", "fast")

      assert message == "Run page refresh has to be a whole number"
      assert Settings.get("run_refresh_ms") == 250
    end

    test "twice leaves one row, not two" do
      assert {:ok, 300} = Settings.put("run_refresh_ms", "300")
      assert {:ok, 400} = Settings.put("run_refresh_ms", "400")

      assert Settings.get("run_refresh_ms") == 400
    end
  end

  test "a key that is not a setting is a mistake rather than a nil" do
    assert_raise ArgumentError, ~r/is not a studio setting/, fn ->
      Settings.get("run-refresh-ms")
    end
  end
end
