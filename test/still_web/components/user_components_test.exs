defmodule StillWeb.UserComponentsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import StillWeb.UserComponents

  describe "users_table/1" do
    test "shows an empty notice with no users" do
      assigns = %{}

      assert rendered_to_string(~H|<.users_table users={[]} current_user_id="x" />|) =~
               "No users yet."
    end
  end
end
