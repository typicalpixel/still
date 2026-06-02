defmodule Still.Agent.SystemdTest do
  use ExUnit.Case, async: true

  alias Still.Agent.Systemd

  describe "parse/1" do
    test "extracts pid, active_state, and active_enter_at from systemctl output" do
      output = """
      MainPID=18421
      ActiveState=active
      ActiveEnterTimestamp=Thu 2026-04-20 15:42:13 UTC
      """

      assert %{
               pid: 18_421,
               active_state: "active",
               active_enter_at: ~U[2026-04-20 15:42:13Z]
             } = Systemd.parse(output)
    end

    test "returns nil pid when MainPID is 0 (unit not running)" do
      output = """
      MainPID=0
      ActiveState=inactive
      ActiveEnterTimestamp=
      """

      assert %{pid: nil, active_state: "inactive", active_enter_at: nil} = Systemd.parse(output)
    end

    test "returns all-nils on empty input" do
      assert %{pid: nil, active_state: nil, active_enter_at: nil} = Systemd.parse("")
    end

    test "ignores lines without an = separator" do
      output = "garbage line\nMainPID=4242\nActiveState=active\n"

      assert %{pid: 4_242, active_state: "active"} = Systemd.parse(output)
    end

    test "tolerates an unparseable ActiveEnterTimestamp" do
      output = """
      MainPID=4242
      ActiveState=active
      ActiveEnterTimestamp=some weird format
      """

      assert %{pid: 4_242, active_enter_at: nil} = Systemd.parse(output)
    end

    test "tolerates a non-numeric MainPID" do
      output = """
      MainPID=notanumber
      ActiveState=active
      """

      assert %{pid: nil, active_state: "active"} = Systemd.parse(output)
    end

    test "treats empty MainPID and ActiveState values as nil" do
      output = """
      MainPID=
      ActiveState=
      ActiveEnterTimestamp=
      """

      assert %{pid: nil, active_state: nil, active_enter_at: nil} = Systemd.parse(output)
    end

    test "returns nil active_enter_at when the timestamp has a plausible shape but invalid fields" do
      # Regex matches YYYY-MM-DD HH:MM:SS UTC; ISO8601 parse rejects the
      # month=13 / day=45 / hour=99 etc.
      output = "ActiveEnterTimestamp=Thu 2026-13-45 99:99:99 UTC\n"

      assert %{active_enter_at: nil} = Systemd.parse(output)
    end
  end

  describe "info_for/2" do
    test "returns an empty shape when slot is nil" do
      assert %{pid: nil, active_state: nil, active_enter_at: nil} =
               Systemd.info_for("my-api", nil)
    end
  end
end
