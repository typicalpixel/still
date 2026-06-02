defmodule Still.Fleet.ServerTest do
  use Still.DataCase, async: false

  alias Still.Fleet.Server

  describe "creation_changeset/2" do
    test "is valid with name, host, and roles" do
      changeset =
        Server.creation_changeset(%Server{}, %{
          name: "app-1",
          host: "10.0.0.5",
          roles: ["application"]
        })

      assert changeset.valid?
    end

    test "requires name, host, and roles" do
      changeset = Server.creation_changeset(%Server{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.host
      assert "can't be blank" in errors.roles
    end

    test "validates name length" do
      too_long =
        Server.creation_changeset(%Server{}, %{
          name: String.duplicate("x", 101),
          host: "10.0.0.5",
          roles: ["application"]
        })

      assert "should be at most 100 character(s)" in errors_on(too_long).name
    end

    test "allows free-form display names with spaces and punctuation" do
      changeset =
        Server.creation_changeset(%Server{}, %{
          name: "Production App Server #1",
          host: "10.0.0.5",
          roles: ["application"]
        })

      assert changeset.valid?
    end

    test "validates host length cap" do
      too_long =
        Server.creation_changeset(%Server{}, %{
          name: "ok",
          host: String.duplicate("a", 256),
          roles: ["application"]
        })

      assert "should be at most 255 character(s)" in errors_on(too_long).host
    end

    test "accepts valid IPv4 hosts" do
      for host <- ["10.0.0.5", "127.0.0.1", "192.168.1.1"] do
        changeset =
          Server.creation_changeset(%Server{}, %{
            name: "ok-#{host}",
            host: host,
            roles: ["application"]
          })

        assert changeset.valid?, "expected #{host} to be valid"
      end
    end

    test "accepts valid IPv6 hosts" do
      for host <- ["::1", "2001:db8::1", "fe80::1"] do
        changeset =
          Server.creation_changeset(%Server{}, %{
            name: "ok-#{host}",
            host: host,
            roles: ["application"]
          })

        assert changeset.valid?, "expected #{host} to be valid"
      end
    end

    test "accepts valid hostnames and FQDNs" do
      for host <- ["app1", "server.example.com", "box.tail-scale.ts.net"] do
        changeset =
          Server.creation_changeset(%Server{}, %{
            name: "ok-#{host}",
            host: host,
            roles: ["application"]
          })

        assert changeset.valid?, "expected #{host} to be valid"
      end
    end

    test "rejects malformed hosts" do
      for host <- ["not a host", "host with spaces", "host/with/slash", "host?q=1"] do
        changeset =
          Server.creation_changeset(%Server{}, %{
            name: "bad",
            host: host,
            roles: ["application"]
          })

        assert "must be a valid IP address or hostname" in (errors_on(changeset)[:host] || []),
               "expected #{inspect(host)} to be rejected"
      end
    end

    test "rejects bracketed IPv6 (the bare form should be used instead)" do
      changeset =
        Server.creation_changeset(%Server{}, %{
          name: "bad",
          host: "[::1]",
          roles: ["application"]
        })

      assert "must be a valid IP address or hostname" in errors_on(changeset).host
    end

    test "rejects unknown roles" do
      changeset =
        Server.creation_changeset(%Server{}, %{
          name: "bad",
          host: "10.0.0.5",
          roles: ["application", "supervillain"]
        })

      assert "has an invalid entry" in errors_on(changeset).roles
    end

    test "accepts each individually-valid role" do
      for role <- Server.valid_roles() do
        changeset =
          Server.creation_changeset(%Server{}, %{
            name: "ok-#{role}",
            host: "10.0.0.#{:erlang.phash2(role, 250) + 1}",
            roles: [role]
          })

        assert changeset.valid?, "expected role #{role} to be valid"
      end
    end

    test "accepts a server with multiple roles" do
      changeset =
        Server.creation_changeset(%Server{}, %{
          name: "all-in-one",
          host: "10.0.0.5",
          roles: ["controller", "ingress", "application"]
        })

      assert changeset.valid?
    end

    test "rejects an empty roles list" do
      changeset =
        Server.creation_changeset(%Server{}, %{
          name: "no-roles",
          host: "10.0.0.5",
          roles: []
        })

      assert "must include at least one role" in errors_on(changeset).roles
    end

    test "defaults metadata to an empty map on a fresh struct" do
      assert %Server{metadata: %{}} = %Server{}
    end
  end

  describe "update_changeset/2" do
    test "casts only name, host, and roles" do
      server = %Server{
        name: "old",
        host: "10.0.0.5",
        roles: ["application"],
        metadata: %{"os" => "Ubuntu"}
      }

      changeset =
        Server.update_changeset(server, %{
          name: "new",
          host: "10.0.0.6",
          roles: ["application", "ingress"],
          metadata: %{"os" => "Debian"},
          last_seen_at: DateTime.utc_now()
        })

      assert changeset.valid?
      assert get_change(changeset, :name) == "new"
      assert get_change(changeset, :host) == "10.0.0.6"
      assert get_change(changeset, :roles) == ["application", "ingress"]
      refute get_change(changeset, :metadata)
      refute get_change(changeset, :last_seen_at)
    end
  end

  describe "valid_roles/0" do
    test "returns the known role set" do
      assert Server.valid_roles() == ~w(controller ingress application)
    end
  end
end
