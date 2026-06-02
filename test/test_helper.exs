ExUnit.start(exclude: [:integration, :integration_root])
Application.ensure_all_started(:credo)
Ecto.Adapters.SQL.Sandbox.mode(Still.Repo, :manual)

# :os_mon spawns C port programs (memsup, cpu_sup, disksup). When the BEAM
# exits, those ports close with a "Erlang has closed" line to stderr.
# Stopping the app cleanly at suite-end closes the ports first and keeps
# the test output free of the noise.
ExUnit.after_suite(fn _result ->
  Application.stop(:os_mon)
end)

# Erlang distribution — required for integration tests that spawn peer
# BEAMs via `:peer.start/1` and call them over the wire.
unless Node.alive?() do
  System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
  :net_kernel.start([:"still_test@127.0.0.1", :longnames])
end

Node.set_cookie(:still_integration_cookie)
