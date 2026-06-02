defmodule Still.Integration.CaddyResumePersistenceTest do
  use Still.IntegrationCase

  @moduledoc """
  Proves the installer's `--resume` contract with a real Caddy: a config
  pushed through the admin API survives a hard `kill -9` plus restart, so
  deployed apps keep serving even when Still — or Caddy — dies. This is the
  durability the install-time drop-in (`caddy run --resume`) buys; see
  scripts/install.sh.

  Spawns its own Caddy with autosave on (`--resume`), separate from the
  shared `IntegrationCase` instance (which disables autosave on purpose).
  Process plumbing and the poll loops live in `Still.IntegrationCase`.
  """

  test "a config pushed via the admin API survives a kill -9 and a --resume restart" do
    admin_port = free_port()
    http_port = free_port()

    home =
      Path.join(System.tmp_dir!(), "still-resume-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)

    # Seed only the admin endpoint on our free port. On first boot there's no
    # autosave, so `--resume` falls back to this; once we push a config the
    # autosave takes over and the seed is never read again.
    seed =
      Path.join(System.tmp_dir!(), "still-resume-seed-#{System.unique_integer([:positive])}.json")

    File.write!(seed, Jason.encode!(%{"admin" => %{"listen" => "localhost:#{admin_port}"}}))

    on_exit(fn ->
      File.rm_rf!(home)
      File.rm_rf!(seed)
    end)

    # First boot — uses the seed (no autosave exists).
    pid1 = start_resume_caddy!(seed, home)
    await_caddy_admin!(admin_port)

    # Push a deliberately off-kilter marker — a route id and body that could
    # never come from the installer, the seed, or CaddyBootstrap — so a match
    # after the restart can only mean *this* pushed config was resumed. Keep
    # the admin block in it so the listener stays on our port after a resume
    # (a full /load replaces everything, including admin).
    marker = "zzz-still-resume-probe-#{System.unique_integer([:positive])}"

    pushed = %{
      "admin" => %{"listen" => "localhost:#{admin_port}"},
      "apps" => %{
        "http" => %{
          "servers" => %{
            "still" => %{
              "listen" => [":#{http_port}"],
              "automatic_https" => %{"disable" => true},
              "routes" => [
                %{
                  "@id" => marker,
                  "handle" => [
                    %{"handler" => "static_response", "status_code" => 200, "body" => marker}
                  ],
                  "terminal" => true
                }
              ]
            }
          }
        }
      }
    }

    assert {:ok, %{status: 200}} =
             Req.post("http://localhost:#{admin_port}/load", json: pushed, retry: false)

    # It's live and serving the marker before the crash.
    assert {:ok, %{status: 200, body: ^marker}} =
             Req.get("http://localhost:#{http_port}/", retry: false)

    # Hard-kill Caddy — a crash / OOM / host reboot, not a graceful stop.
    System.cmd("kill", ["-9", to_string(pid1)], stderr_to_stdout: true)
    await_caddy_down!(admin_port)

    # Restart exactly as the installer's drop-in does.
    pid2 = start_resume_caddy!(seed, home)
    on_exit(fn -> System.cmd("kill", ["-9", to_string(pid2)], stderr_to_stdout: true) end)
    await_caddy_admin!(admin_port)

    # The pushed config came back — Caddy resumed the autosave, not the seed.
    # Req decodes the application/json body to a map for us.
    {:ok, %{status: 200, body: config}} =
      Req.get("http://localhost:#{admin_port}/config/", retry: false)

    routes = get_in(config, ["apps", "http", "servers", "still", "routes"])
    assert Enum.any?(routes, &(&1["@id"] == marker))

    # And it's serving the exact marker again on the same port, without Still.
    assert {:ok, %{status: 200, body: ^marker}} =
             Req.get("http://localhost:#{http_port}/", retry: false)
  end
end
