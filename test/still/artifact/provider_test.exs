defmodule Still.Artifact.ProviderTest do
  use ExUnit.Case, async: true

  alias Still.Artifact.Provider

  describe "for_type/1" do
    test "returns the URL provider for :unauthenticated_url" do
      assert {:ok, Still.Artifact.Provider.URL} = Provider.for_type(:unauthenticated_url)
    end

    test "returns an error for an unregistered type" do
      assert {:error, :unsupported_provider} = Provider.for_type(:gcs)
    end
  end
end
