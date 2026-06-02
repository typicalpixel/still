defmodule Still.Applications.ArtifactSourceTest do
  use ExUnit.Case, async: true

  alias Still.Applications.ArtifactSource

  describe "changeset/2" do
    test "is valid for :unauthenticated_url" do
      changeset = ArtifactSource.changeset(%ArtifactSource{}, %{type: :unauthenticated_url})
      assert changeset.valid?
    end

    test "requires type" do
      changeset = ArtifactSource.changeset(%ArtifactSource{}, %{})
      assert "can't be blank" in errors_on(changeset).type
    end

    test "rejects unknown types" do
      changeset = ArtifactSource.changeset(%ArtifactSource{}, %{type: :ftp})
      assert "is invalid" in errors_on(changeset).type
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
