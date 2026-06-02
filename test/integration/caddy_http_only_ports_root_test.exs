defmodule Still.Integration.CaddyHttpOnlyPortsRootTest do
  @moduledoc """
  Root-level proof that an HTTP-only (`tls_mode: :off`) install never binds
  a privileged port. Reconciles a bootstrap config against a real Caddy
  running as root and inspects the process's actual listening sockets with
  `ss`: it must own the chosen HTTP port and neither `:80` nor `:443`.

  Regression test for the automatic_https leak — the internal artifacts
  server left auto-HTTPS enabled, which made Caddy open the shared `:80`
  ACME/redirect listener even when the operator opted out of TLS. Needs
  root because binding (or refusing to bind) `:80`/`:443` is only
  observable when the process is allowed to try.
  """

  use Still.IntegrationCase, root: true

  alias Still.CaddyBootstrap

  test "tls_mode :off binds the http port only — never :80 or :443", %{caddy: caddy} do
    # A controller_domain makes auto-HTTPS tempting; the fix must still
    # keep every still-managed server off the privileged ports.
    assert :ok =
             CaddyBootstrap.reconcile(
               backend: "localhost:4000",
               http_port: caddy.http_port,
               controller_domain: "still.example.com",
               tls_mode: :off
             )

    # Caddy's /load provisions and starts listeners before it responds, so
    # the socket state is final once reconcile returns :ok.
    ports = caddy_listen_ports(caddy.os_pid)

    assert caddy.http_port in ports,
           "expected Caddy to listen on the configured http port #{caddy.http_port}, got #{inspect(ports)}"

    refute 80 in ports, "Caddy bound :80 under tls_mode :off — got #{inspect(ports)}"
    refute 443 in ports, "Caddy bound :443 under tls_mode :off — got #{inspect(ports)}"
  end

  # Listening TCP ports owned by the given OS pid, parsed from `ss`.
  # `-H` drops the header; the local address:port is the 4th column and
  # covers `*:80`, `0.0.0.0:80`, `[::]:80`, `127.0.0.1:2019` alike.
  defp caddy_listen_ports(os_pid) do
    {out, 0} = System.cmd("ss", ["-ltnpH"], stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "pid=#{os_pid},"))
    |> Enum.map(fn line ->
      line
      |> String.split()
      |> Enum.at(3)
      |> String.split(":")
      |> List.last()
      |> String.to_integer()
    end)
  end
end
