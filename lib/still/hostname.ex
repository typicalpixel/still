defmodule Still.Hostname do
  @moduledoc """
  Hostname validation shared by Server hosts and Application domains.
  """

  @doc """
  Returns `true` if the given string is a valid IPv4 address, IPv6 address,
  or RFC-shaped hostname.

  Combines `:inet.parse_strict_address/1` for IPs with a URI-authority
  round-trip for hostnames — no regex.
  """
  def valid?(host) when is_binary(host) and byte_size(host) > 0 do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, _addr} -> true
      {:error, _} -> valid_uri_host?(host)
    end
  end

  def valid?(_host), do: false

  # A string is a valid hostname iff it parses as the entire `:host` of a URI
  # authority with no path/query/fragment leakage.
  defp valid_uri_host?(host) do
    case URI.new("http://#{host}") do
      {:ok, %URI{host: ^host, path: nil, query: nil, fragment: nil}} -> true
      _ -> false
    end
  end
end
