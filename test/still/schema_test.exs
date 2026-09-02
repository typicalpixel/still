defmodule Still.SchemaTest.Sample do
  @moduledoc false
  use Still.Schema

  schema "schema_test_samples" do
    field :name, :string
    belongs_to :parent, Still.SchemaTest.Sample
    timestamps()
  end
end

defmodule Still.SchemaTest do
  use ExUnit.Case, async: false

  alias Still.SchemaTest.Sample

  test "schemas get binary_id primary and foreign keys" do
    assert Sample.__schema__(:type, :id) == :binary_id
    assert Sample.__schema__(:type, :parent_id) == :binary_id
    assert Sample.__schema__(:autogenerate_id) == {:id, :id, :binary_id}
  end

  test "schemas get microsecond UTC timestamps" do
    assert Sample.__schema__(:type, :inserted_at) == :utc_datetime_usec
    assert Sample.__schema__(:type, :updated_at) == :utc_datetime_usec
  end
end
