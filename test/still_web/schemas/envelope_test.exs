defmodule StillWeb.Schemas.EnvelopeTest do
  use ExUnit.Case, async: true

  alias OpenApiSpex.Schema
  alias StillWeb.Schemas.{Envelope, User}

  describe "list/1" do
    test "wraps a schema module as an array under :data" do
      assert %Schema{
               type: :object,
               required: [:data],
               properties: %{data: %Schema{type: :array, items: User}}
             } = Envelope.list(User)
    end

    test "accepts an inline %Schema{} too" do
      inline = %Schema{type: :string}
      assert %Schema{properties: %{data: %Schema{items: ^inline}}} = Envelope.list(inline)
    end
  end

  describe "single/1" do
    test "wraps a schema module under :data" do
      assert %Schema{
               type: :object,
               required: [:data],
               properties: %{data: User}
             } = Envelope.single(User)
    end
  end
end
