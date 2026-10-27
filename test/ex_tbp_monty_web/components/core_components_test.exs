defmodule ExTbpMontyWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import ExTbpMontyWeb.CoreComponents

  defp form(params \\ %{"name" => "cube", "public" => "true"}) do
    to_form(params, as: :experiment)
  end

  defp form_with_errors do
    to_form(%{"name" => nil},
      as: :experiment,
      errors: [name: {"can't be blank", [validation: :required]}]
    )
  end

  describe "input/1" do
    test "renders a text input bound to the form field" do
      html = render_component(&input/1, type: "text", field: form()[:name], label: "Name")

      assert html =~ ~s(name="experiment[name]")
      assert html =~ ~s(value="cube")
      assert html =~ "Name"
    end

    test "shows the changeset's message next to the field" do
      html =
        render_component(&input/1, type: "text", field: form_with_errors()[:name], label: "Name")

      assert html =~ "can&#39;t be blank"
    end

    test "renders a checkbox that reflects the value" do
      html = render_component(&input/1, type: "checkbox", field: form()[:public], label: "Public")

      assert html =~ ~s(type="checkbox")
      assert html =~ "checked"
    end

    test "renders a select with its options and prompt" do
      html =
        render_component(&input/1,
          type: "select",
          field: form()[:name],
          label: "Object",
          prompt: "Pick one",
          options: [{"Cube", "cube"}, {"Sphere", "sphere"}]
        )

      assert html =~ ~s(value="cube")
      assert html =~ "Cube"
      assert html =~ "Sphere"
      assert html =~ "Pick one"
    end

    test "renders a textarea" do
      html = render_component(&input/1, type: "textarea", field: form()[:name], label: "Notes")

      assert html =~ "<textarea"
      assert html =~ "cube"
    end
  end
end
