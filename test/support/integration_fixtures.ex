defmodule Still.IntegrationFixtures do
  @moduledoc """
  Downloads and caches prebuilt deployment fixture tarballs from the sibling
  fixture repos on GitHub. Returns a local `file://` URL suitable for passing
  to `DeploymentManager` as `artifact_url`.

  Fixture pins (repo + tag) are declared at the top of this module. Bump a
  tag when you want to move to a new fixture version and the next test run
  will redownload. Filenames are derived from the tag.

  Cache directory: `test/support/fixtures/cache/` (gitignored). Delete it to
  force a fresh download.
  """

  # six:ignore:start

  # Pinned fixture sources — bump these to update.
  @static_repo "typicalpixel/static_site"
  @static_tag "v0.0.1"

  @release_repo "typicalpixel/elixir_release"
  @release_tag "v0.0.1"

  # The upstream repos name their tarballs slightly differently: static
  # filenames drop the leading `v` from the version; release filenames keep
  # it. Both are derived from the tag here so bumping the tag is one edit.
  @static_filename_version String.trim_leading(@static_tag, "v")
  @release_filename_version @release_tag

  @cache_dir Path.expand("fixtures/cache", __DIR__)

  @fixtures %{
    static_a: %{
      repo: @static_repo,
      tag: @static_tag,
      filename: "still_fixture_static-vA-#{@static_filename_version}.tar.gz",
      size: 23_617
    },
    static_b: %{
      repo: @static_repo,
      tag: @static_tag,
      filename: "still_fixture_static-vB-#{@static_filename_version}.tar.gz",
      size: 23_614
    },
    release_a: %{
      repo: @release_repo,
      tag: @release_tag,
      filename: "elixir_release-vA-#{@release_filename_version}.tar.gz",
      size: 27_036_928
    },
    release_b: %{
      repo: @release_repo,
      tag: @release_tag,
      filename: "elixir_release-vB-#{@release_filename_version}.tar.gz",
      size: 27_036_930
    }
  }

  @doc """
  Returns the absolute local path to the named fixture, downloading into the
  cache if the file is missing or its size does not match the pinned value.
  """
  def path(name) when is_atom(name) do
    fixture = Map.fetch!(@fixtures, name)
    cached = Path.join(@cache_dir, fixture.filename)

    if cached?(cached, fixture.size) do
      cached
    else
      download!(url_for(fixture), cached)
      cached
    end
  end

  @doc """
  Returns a `file://` URL for the named fixture, suitable for passing to
  `Still.Agent.DeploymentManager` as `artifact_url`.
  """
  def file_url(name), do: "file://" <> path(name)

  defp url_for(%{repo: repo, tag: tag, filename: filename}) do
    "https://github.com/#{repo}/releases/download/#{tag}/#{filename}"
  end

  defp cached?(path, expected_size) do
    case File.stat(path) do
      {:ok, %File.Stat{size: ^expected_size}} -> true
      _ -> false
    end
  end

  defp download!(url, dest) do
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, Req.get!(url).body)
  end

  # six:ignore:stop
end
