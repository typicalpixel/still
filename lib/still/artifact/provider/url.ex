defmodule Still.Artifact.Provider.URL do
  @moduledoc """
  Downloads artifacts from a plain HTTP/HTTPS URL.
  """

  @behaviour Still.Artifact.Provider

  @doc "Downloads the artifact at `spec.artifact_url` to `dest_path` over HTTP."
  @impl true
  def download(spec, dest_path) when is_map(spec) and is_binary(dest_path) do
    opts = [
      url: spec.artifact_url,
      into: File.stream!(dest_path),
      decode_body: false,
      raw: true
    ]

    case Req.get(req(), opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, "download failed: HTTP #{status}"}

      {:error, reason} ->
        {:error, "download failed: #{inspect(reason)}"}
    end
  end

  defp req do
    Req.new(req_options())
  end

  defp req_options do
    Application.get_env(:still, :artifact_req_options, [])
  end
end
