defmodule Still.Applications.ApplicationServerTest do
  use Still.DataCase, async: false

  alias Still.Applications.ApplicationServer

  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  describe "assignment_changeset/2" do
    setup do
      app = application_fixture()
      server = server_fixture()
      %{app: app, server: server}
    end

    test "is valid with all required fields", %{app: app, server: server} do
      changeset =
        ApplicationServer.assignment_changeset(%ApplicationServer{}, %{
          application_id: app.id,
          server_id: server.id,
          port_blue: 20_000,
          port_green: 20_001
        })

      assert changeset.valid?
    end

    test "requires application_id, server_id, port_blue, port_green" do
      changeset = ApplicationServer.assignment_changeset(%ApplicationServer{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.application_id
      assert "can't be blank" in errors.server_id
      assert "can't be blank" in errors.port_blue
      assert "can't be blank" in errors.port_green
    end

    test "rejects ports outside the legal TCP range", %{app: app, server: server} do
      for invalid <- [0, -1, 65_536, 70_000] do
        changeset =
          ApplicationServer.assignment_changeset(%ApplicationServer{}, %{
            application_id: app.id,
            server_id: server.id,
            port_blue: invalid,
            port_green: 20_001
          })

        refute changeset.valid?, "expected port_blue=#{invalid} to be rejected"
      end
    end

    test "rejects matching port_blue and port_green", %{app: app, server: server} do
      changeset =
        ApplicationServer.assignment_changeset(%ApplicationServer{}, %{
          application_id: app.id,
          server_id: server.id,
          port_blue: 20_000,
          port_green: 20_000
        })

      assert "must differ from port_blue" in errors_on(changeset).port_green
    end

    test "skips the distinct check when one port is missing", %{app: app, server: server} do
      changeset =
        ApplicationServer.assignment_changeset(%ApplicationServer{}, %{
          application_id: app.id,
          server_id: server.id,
          port_blue: 20_000
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).port_green
      refute Enum.any?(errors_on(changeset).port_green, &(&1 =~ "must differ"))
    end
  end
end
