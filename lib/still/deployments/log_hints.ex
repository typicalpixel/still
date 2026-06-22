defmodule Still.Deployments.LogHints do
  @moduledoc """
  Pattern-matches a captured deploy log against known failure signatures and
  returns an actionable hint. Seeded from the boot failures that motivated
  deploy-log capture — node-name collisions, Doppler auth, database refusals,
  and unset env vars — where the journal already says what's wrong but a reader
  who didn't write the app won't know the fix.

  Returns `%{title:, body:}` for the first signature that matches, or `nil`.
  """

  @doc """
  Returns a hint for the first matching failure signature in `log`, or `nil`
  when nothing matches (or `log` is `nil`/non-binary).
  """
  def hint_for(log) when is_binary(log) do
    Enum.find_value(rules(), fn {regex, build} ->
      case Regex.run(regex, log) do
        nil -> nil
        captures -> build.(captures)
      end
    end)
  end

  def hint_for(_log), do: nil

  # Anchored to real failure signatures, not bare keywords — a confidently-wrong
  # hint at the top of an incident panel misdirects Ops. Doppler needs an auth
  # error word (not a bare "token"); the DB rule keys off Elixir DB error structs
  # or an explicit connect failure (not a healthy "Postgrex connected"); the node
  # collision requires the full Erlang phrase.
  defp rules do
    [
      {~r/seems to be in use by another Erlang node/i, fn _ -> node_name_collision() end},
      {~r/doppler.{0,80}(unauthorized|invalid|forbidden|401|403)/is, fn _ -> doppler_auth() end},
      # Auth failure before unreachability: a wrong-password error also mentions
      # Postgrex.Error, and "the server is up, the credentials are wrong" is a
      # different fix than "the server can't be reached".
      {~r/(password authentication failed|invalid_password|28P01|authentication failed for user)/i,
       fn _ -> database_auth() end},
      {~r/(Postgrex\.Error|DBConnection\.ConnectionError|MyXQL\.Error|could not connect to (?:server|database)|connection to server .* failed)/i,
       fn _ -> database_unreachable() end},
      {~r/could not fetch environment variable "([^"]+)"/, fn [_, var] -> missing_env(var) end}
    ]
  end

  defp node_name_collision do
    %{
      title: "Node-name collision",
      body:
        "Both slots booted the same Erlang node name. Derive a per-slot RELEASE_NODE " <>
          "from STILL_TARGET_SLOT in rel/env.sh.eex so blue and green don't share a node " <>
          "name while both are briefly live during a flip."
    }
  end

  defp doppler_auth do
    %{
      title: "Doppler authentication failed",
      body:
        "Doppler rejected the request — usually an expired or wrong DOPPLER_TOKEN. " <>
          "Check the token in the application's environment variables."
    }
  end

  defp database_auth do
    %{
      title: "Database authentication failed",
      body:
        "The database rejected the credentials — the server is reachable, but the " <>
          "user/password (or role) is wrong. Check the database credentials in the " <>
          "application's environment variables."
    }
  end

  defp database_unreachable do
    %{
      title: "Database unreachable",
      body:
        "The application couldn't reach its database on boot. Verify the database host " <>
          "and port, that it accepts connections from this server, and the credentials in " <>
          "the application's environment variables."
    }
  end

  defp missing_env(var) do
    %{
      title: "Missing environment variable: #{var}",
      body:
        "The application required #{var} at boot but it wasn't set. Add it to the " <>
          "application's environment variables and redeploy."
    }
  end
end
