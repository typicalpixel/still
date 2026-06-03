defmodule Still.Applications.ApplicationTest do
  use Still.DataCase, async: false

  alias Still.Applications.Application

  import Still.ApplicationsFixtures

  defp valid_elixir_release_attrs(overrides \\ %{}) do
    Enum.into(overrides, %{
      name: "my-api",
      type: :elixir_release,
      domain: "api.example.com",
      exec_command: "bin/my_api start",
      env_vars: %{},
      min_healthy: 1,
      health_check: valid_health_check_attrs(),
      artifact_source: valid_artifact_source_attrs()
    })
  end

  defp valid_static_site_attrs(overrides \\ %{}) do
    Enum.into(overrides, %{
      name: "my-site",
      type: :static_site,
      domain: "site.example.com",
      env_vars: %{},
      min_healthy: 1,
      artifact_source: valid_artifact_source_attrs()
    })
  end

  describe "creation_changeset/2 — base validity" do
    test "is valid for an :elixir_release with all required fields" do
      changeset = Application.creation_changeset(%Application{}, valid_elixir_release_attrs())
      assert changeset.valid?
    end

    test "is valid for a :static_site without exec_command or health_check" do
      changeset = Application.creation_changeset(%Application{}, valid_static_site_attrs())
      assert changeset.valid?
    end

    test "is valid for a :process with health_check and exec_command" do
      attrs = valid_elixir_release_attrs(%{type: :process, exec_command: "/usr/bin/myproc"})
      changeset = Application.creation_changeset(%Application{}, attrs)
      assert changeset.valid?
    end

    test "requires name, type, domain, min_healthy, and artifact_source" do
      changeset = Application.creation_changeset(%Application{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.type
      assert "can't be blank" in errors.domain
      assert "can't be blank" in errors.artifact_source
    end
  end

  describe "creation_changeset/2 — name slug" do
    test "rejects names that don't start with a lowercase letter" do
      for bad <- ["1app", "-app", "_app", "App"] do
        changeset =
          Application.creation_changeset(%Application{}, valid_elixir_release_attrs(%{name: bad}))

        refute changeset.valid?, "expected #{inspect(bad)} to be rejected"
      end
    end

    test "accepts hyphens, underscores, and digits after the first letter" do
      for ok <- ["my-api", "marketing_site", "v2-app", "a"] do
        changeset =
          Application.creation_changeset(%Application{}, valid_elixir_release_attrs(%{name: ok}))

        assert changeset.valid?, "expected #{inspect(ok)} to be valid"
      end
    end

    test "validates name length" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{name: String.duplicate("a", 101)})
        )

      assert "should be at most 100 character(s)" in errors_on(changeset).name
    end
  end

  describe "creation_changeset/2 — domain" do
    test "accepts a valid hostname" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{domain: "api.example.com"})
        )

      assert changeset.valid?
    end

    test "rejects a malformed domain" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{domain: "not a domain"})
        )

      assert "must be a valid IP address or hostname" in errors_on(changeset).domain
    end

    test "validates domain length" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{domain: String.duplicate("a", 256)})
        )

      assert "should be at most 255 character(s)" in errors_on(changeset).domain
    end
  end

  describe "creation_changeset/2 — path_prefix" do
    test "accepts a path_prefix that starts with /" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{path_prefix: "/api"})
        )

      assert changeset.valid?
    end

    test "is valid when path_prefix is omitted" do
      attrs = valid_elixir_release_attrs() |> Map.delete(:path_prefix)
      changeset = Application.creation_changeset(%Application{}, attrs)
      assert changeset.valid?
    end

    test "rejects path_prefix without a leading slash" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{path_prefix: "api"})
        )

      assert "must start with /" in errors_on(changeset).path_prefix
    end
  end

  describe "creation_changeset/2 — min_healthy" do
    test "rejects min_healthy < 1" do
      for invalid <- [0, -1] do
        changeset =
          Application.creation_changeset(
            %Application{},
            valid_elixir_release_attrs(%{min_healthy: invalid})
          )

        assert "must be greater than or equal to 1" in errors_on(changeset).min_healthy
      end
    end
  end

  describe "creation_changeset/2 — env_vars" do
    test "accepts string keys and string values" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{env_vars: %{"FOO" => "bar", "BAZ_2" => "qux"}})
        )

      assert changeset.valid?
    end

    test "rejects non-string keys" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{env_vars: %{foo: "bar"}})
        )

      assert "keys must be strings" in errors_on(changeset).env_vars
    end

    test "rejects keys that aren't valid env var names" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{env_vars: %{"1BAD" => "x"}})
        )

      assert Enum.any?(errors_on(changeset).env_vars, &(&1 =~ "must match"))
    end

    test "rejects non-string values (would crash the deploy that writes the env file)" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{env_vars: %{"FOO" => 5}})
        )

      assert "value for FOO must be a string" in errors_on(changeset).env_vars
    end

    test "rejects values containing newlines (env-file injection)" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{env_vars: %{"FOO" => "a\nINJECTED=1"}})
        )

      assert "value for FOO must not contain newlines or null bytes" in errors_on(changeset).env_vars
    end

    test "normalizes keys to uppercase-with-underscores" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{env_vars: %{"database-url" => "x", "Mix.Env" => "prod"}})
        )

      assert changeset.valid?
      assert get_change(changeset, :env_vars) == %{"DATABASE_URL" => "x", "MIX_ENV" => "prod"}
    end
  end

  describe "creation_changeset/2 — type-conditional rules" do
    test ":static_site rejects exec_command" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_static_site_attrs(%{exec_command: "bin/start"})
        )

      assert "must be blank for static_site applications" in errors_on(changeset).exec_command
    end

    test ":static_site rejects health_check" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_static_site_attrs(%{health_check: valid_health_check_attrs()})
        )

      assert "must be blank for static_site applications" in errors_on(changeset).health_check
    end

    test ":elixir_release requires exec_command" do
      attrs = valid_elixir_release_attrs() |> Map.delete(:exec_command)
      changeset = Application.creation_changeset(%Application{}, attrs)
      assert "can't be blank" in errors_on(changeset).exec_command
    end

    test ":elixir_release allows optional exec_start_pre and exec_stop" do
      attrs =
        valid_elixir_release_attrs(%{
          exec_start_pre: "bin/my_api eval MyApi.Release.migrate",
          exec_stop: "bin/my_api stop"
        })

      changeset = Application.creation_changeset(%Application{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :exec_start_pre) == "bin/my_api eval MyApi.Release.migrate"
      assert get_change(changeset, :exec_stop) == "bin/my_api stop"
    end

    test ":elixir_release is valid without exec_start_pre or exec_stop" do
      changeset = Application.creation_changeset(%Application{}, valid_elixir_release_attrs())
      assert changeset.valid?
    end

    test ":static_site rejects exec_start_pre and exec_stop" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_static_site_attrs(%{exec_start_pre: "bin/start", exec_stop: "bin/stop"})
        )

      errors = errors_on(changeset)
      assert "must be blank for static_site applications" in errors.exec_start_pre
      assert "must be blank for static_site applications" in errors.exec_stop
    end

    test ":elixir_release requires health_check" do
      attrs = valid_elixir_release_attrs() |> Map.delete(:health_check)
      changeset = Application.creation_changeset(%Application{}, attrs)
      assert "is required" in errors_on(changeset).health_check
    end

    test ":process requires exec_command and health_check" do
      attrs =
        valid_elixir_release_attrs(%{type: :process})
        |> Map.delete(:exec_command)
        |> Map.delete(:health_check)

      changeset = Application.creation_changeset(%Application{}, attrs)
      errors = errors_on(changeset)
      assert "can't be blank" in errors.exec_command
      assert "is required" in errors.health_check
    end
  end

  describe "creation_changeset/2 — embedded validation propagation" do
    test "surfaces health_check errors at the embed" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{
            health_check: %{path: "no-slash", interval_ms: 5000, deadline_ms: 3000}
          })
        )

      assert "must start with /" in errors_on(changeset).health_check.path
    end

    test "surfaces artifact_source errors at the embed" do
      changeset =
        Application.creation_changeset(
          %Application{},
          valid_elixir_release_attrs(%{artifact_source: %{type: :ftp}})
        )

      assert "is invalid" in errors_on(changeset).artifact_source.type
    end
  end

  describe "update_changeset/2" do
    setup do
      app = application_fixture()
      %{app: app}
    end

    test "casts mutable fields", %{app: app} do
      changeset =
        Application.update_changeset(app, %{
          domain: "new.example.com",
          path_prefix: "/v2",
          exec_command: "bin/new start",
          env_vars: %{"FOO" => "bar"},
          min_healthy: 2
        })

      assert changeset.valid?
      assert get_change(changeset, :domain) == "new.example.com"
      assert get_change(changeset, :path_prefix) == "/v2"
      assert get_change(changeset, :exec_command) == "bin/new start"
      assert get_change(changeset, :env_vars) == %{"FOO" => "bar"}
      assert get_change(changeset, :min_healthy) == 2
    end

    test "normalizes env var keys", %{app: app} do
      changeset = Application.update_changeset(app, %{env_vars: %{"database-url" => "x"}})

      assert changeset.valid?
      assert get_change(changeset, :env_vars) == %{"DATABASE_URL" => "x"}
    end

    test "ignores attempts to change name and type", %{app: app} do
      changeset =
        Application.update_changeset(app, %{
          name: "renamed",
          type: :static_site
        })

      refute get_change(changeset, :name)
      refute get_change(changeset, :type)
    end
  end

  describe "types/0" do
    test "returns the known type set" do
      assert Application.types() == [:elixir_release, :static_site, :process]
    end
  end
end
