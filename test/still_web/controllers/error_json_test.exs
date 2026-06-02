defmodule StillWeb.ErrorJSONTest do
  use StillWeb.ConnCase, async: false

  test "renders 404" do
    assert StillWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert StillWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
