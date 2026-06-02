defmodule StillWeb.CoreComponentsTest.StreamTableLive do
  @moduledoc false
  use StillWeb, :live_view

  import StillWeb.CoreComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :rows, [%{id: "r1", name: "Ada"}])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.table id="stream-table" rows={@streams.rows}>
        <:col :let={{_dom_id, row}} label="Name">{row.name}</:col>
      </.table>
    </div>
    """
  end
end

defmodule StillWeb.CoreComponentsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import StillWeb.CoreComponents

  describe "flash/1" do
    test "renders an info flash from the flash map" do
      assigns = %{}
      html = rendered_to_string(~H|<.flash kind={:info} flash={%{"info" => "Saved!"}} />|)
      assert html =~ "Saved!"
      assert html =~ "alert-info"
    end

    test "renders an error flash with a title and inner block" do
      assigns = %{}
      html = rendered_to_string(~H|<.flash kind={:error} title="Oops">Bad thing</.flash>|)
      assert html =~ "Bad thing"
      assert html =~ "Oops"
      assert html =~ "alert-error"
    end
  end

  describe "button/1" do
    test "renders a plain button" do
      assigns = %{}
      html = rendered_to_string(~H|<.button>Save</.button>|)
      assert html =~ "Save"
      assert html =~ "btn"
    end

    test "renders a primary button" do
      assigns = %{}
      html = rendered_to_string(~H|<.button variant="primary">Go</.button>|)
      assert html =~ "btn-primary"
    end

    test "renders a navigation button as a link" do
      assigns = %{}
      html = rendered_to_string(~H|<.button navigate="/somewhere">Home</.button>|)
      assert html =~ "<a"
      assert html =~ "Home"
    end
  end

  describe "input/1" do
    test "renders a text input from a form field" do
      assigns = %{form: to_form(%{"name" => "Ada"}, as: :user)}
      html = rendered_to_string(~H|<.input field={@form[:name]} type="text" label="Name" />|)
      assert html =~ "Name"
      assert html =~ ~s(value="Ada")
    end

    test "renders a hidden input" do
      assigns = %{}
      html = rendered_to_string(~H|<.input type="hidden" name="x" value="y" />|)
      assert html =~ ~s(type="hidden")
    end

    test "renders a checkbox input" do
      assigns = %{}
      html = rendered_to_string(~H|<.input type="checkbox" name="ok" label="OK" value={true} />|)
      assert html =~ ~s(type="checkbox")
      assert html =~ "OK"
    end

    test "renders a select input" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.input type="select" name="role" label="Role" value="admin" options={[{"Admin", "admin"}]} prompt="Pick" />|
        )

      assert html =~ "<select"
      assert html =~ "Admin"
      assert html =~ "Pick"
    end

    test "renders a textarea input" do
      assigns = %{}
      html = rendered_to_string(~H|<.input type="textarea" name="bio" label="Bio" value="hi" />|)
      assert html =~ "<textarea"
      assert html =~ "hi"
    end

    test "renders error messages" do
      assigns = %{}
      html = rendered_to_string(~H|<.input name="x" id="x" value="bad" errors={["oh no!"]} />|)
      assert html =~ "oh no!"
      assert html =~ "input-error"
    end

    test "renders a select input with errors" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.input type="select" name="role" value="admin" options={[{"Admin", "admin"}]} errors={["required"]} />|
        )

      assert html =~ "select-error"
      assert html =~ "required"
    end

    test "renders a textarea input with errors" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.input type="textarea" name="bio" value="x" errors={["too short"]} />|
        )

      assert html =~ "textarea-error"
      assert html =~ "too short"
    end
  end

  describe "header/1" do
    test "renders with subtitle and actions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>
          Title
          <:subtitle>Sub</:subtitle>
          <:actions>Act</:actions>
        </.header>
        """)

      assert html =~ "Title"
      assert html =~ "Sub"
      assert html =~ "Act"
    end

    test "renders without optional slots" do
      assigns = %{}
      html = rendered_to_string(~H|<.header>Just a title</.header>|)
      assert html =~ "Just a title"
    end
  end

  describe "table/1" do
    test "renders rows with columns and an action slot" do
      assigns = %{rows: [%{id: 1, name: "Ada"}]}

      html =
        rendered_to_string(~H"""
        <.table id="users" rows={@rows} row_click={fn row -> "click-#{row.id}" end}>
          <:col :let={u} label="Name">{u.name}</:col>
          <:action :let={u}>edit-{u.id}</:action>
        </.table>
        """)

      assert html =~ "Name"
      assert html =~ "Ada"
      assert html =~ "edit-1"
    end
  end

  describe "table/1 with a LiveStream" do
    test "assigns a default row id and renders streamed rows", %{conn: conn} do
      {:ok, _lv, html} =
        live_isolated(conn, StillWeb.CoreComponentsTest.StreamTableLive)

      assert html =~ "Name"
      assert html =~ "Ada"
      assert html =~ ~s(id="stream-table")
    end
  end

  describe "list/1" do
    test "renders titled items" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.list>
          <:item title="Status">running</:item>
        </.list>
        """)

      assert html =~ "Status"
      assert html =~ "running"
    end
  end

  describe "icon/1" do
    test "renders a heroicon span" do
      assigns = %{}
      html = rendered_to_string(~H|<.icon name="hero-x-mark" />|)
      assert html =~ "hero-x-mark"
    end
  end

  describe "JS command helpers" do
    test "show/1 and hide/1 return JS structs" do
      assert %Phoenix.LiveView.JS{} = show("#thing")
      assert %Phoenix.LiveView.JS{} = hide("#thing")
    end
  end

  describe "translate_error/1 and translate_errors/2" do
    test "translates a simple error" do
      assert translate_error({"is invalid", []}) == "is invalid"
    end

    test "translates an error with a count" do
      msg = translate_error({"should be at least %{count} character(s)", [count: 3]})
      assert msg =~ "3"
    end

    test "translates errors for a field" do
      errors = [name: {"is invalid", []}, email: {"is taken", []}]
      assert translate_errors(errors, :name) == ["is invalid"]
    end
  end
end
