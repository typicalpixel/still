defmodule StillWeb.OriginPolicy do
  @moduledoc """
  Resolves the endpoint's `:check_origin` value for the running install.
  """

  @doc """
  Computes `:check_origin` from the controller domain and an optional
  operator override:

    * `override` — a comma-separated allow-list (from `STILL_CHECK_ORIGIN`),
      used verbatim. Write entries as `//host` to match a host across
      schemes and ports, which is what you want behind a TLS edge.
    * a `domain` with no override — strict to that host (`["//domain"]`).
    * neither — `false`, accepting any origin. `/live` is gated by
      a per-session CSRF token plus the `SameSite=Lax` session cookie. Set a
      domain to enforce origin on top.
  """
  def check_origin(domain, override)
      when (is_binary(domain) or is_nil(domain)) and (is_binary(override) or is_nil(override)) do
    case parse_list(override) do
      [] -> from_domain(domain)
      list -> list
    end
  end

  defp from_domain(domain) do
    if present?(domain), do: ["//" <> String.trim(domain)], else: false
  end

  defp parse_list(nil), do: []

  defp parse_list(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
