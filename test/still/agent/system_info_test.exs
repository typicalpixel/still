defmodule Still.Agent.SystemInfoTest do
  use ExUnit.Case, async: false

  alias Still.Agent.SystemInfo

  describe "collect/1" do
    test "returns a map with the documented keys" do
      assert %{
               hostname: _,
               os: _,
               cpu_count: _,
               memory_mb: _,
               disk_free_mb: _,
               agent_version: _
             } = SystemInfo.collect("/tmp")
    end

    test "hostname is a non-empty string" do
      assert %{hostname: hostname} = SystemInfo.collect("/tmp")
      assert is_binary(hostname)
      assert String.length(hostname) > 0
    end

    test "cpu_count is a positive integer" do
      assert %{cpu_count: cpu_count} = SystemInfo.collect("/tmp")
      assert is_integer(cpu_count)
      assert cpu_count >= 1
    end

    test "memory_mb is a positive integer" do
      assert %{memory_mb: mb} = SystemInfo.collect("/tmp")
      assert is_integer(mb)
      assert mb > 0
    end

    test "disk_free_mb is nil when applications_dir is nil" do
      assert %{disk_free_mb: nil} = SystemInfo.collect(nil)
    end

    test "os is a non-empty string" do
      assert %{os: os} = SystemInfo.collect("/tmp")
      assert is_binary(os)
      assert String.length(os) > 0
    end

    test "agent_version matches the :still application version" do
      {:ok, vsn} = :application.get_key(:still, :vsn)
      assert %{agent_version: version} = SystemInfo.collect("/tmp")
      assert version == to_string(vsn)
    end
  end

  describe "parse_pretty_name/1" do
    test "extracts the quoted PRETTY_NAME value" do
      contents = ~s(NAME="Ubuntu"\nPRETTY_NAME="Ubuntu 24.04.1 LTS"\nVERSION_ID="24.04"\n)
      assert SystemInfo.parse_pretty_name(contents) == "Ubuntu 24.04.1 LTS"
    end

    test "returns nil when PRETTY_NAME is absent" do
      contents = ~s(NAME="Arch"\nID=arch\n)
      assert SystemInfo.parse_pretty_name(contents) == nil
    end

    test "returns nil on empty input" do
      assert SystemInfo.parse_pretty_name("") == nil
    end

    test "tolerates lines without an = sign" do
      contents = "not-a-pair\nPRETTY_NAME=\"Debian\"\n"
      assert SystemInfo.parse_pretty_name(contents) == "Debian"
    end
  end

  describe "os/1" do
    test "extracts PRETTY_NAME when the file is present" do
      path = Path.join(System.tmp_dir!(), "still-os-release-#{:rand.uniform(1_000_000)}")
      File.write!(path, ~s(PRETTY_NAME="Alpine Linux 3.20"\n))
      on_exit(fn -> File.rm(path) end)

      assert SystemInfo.os(path) == "Alpine Linux 3.20"
    end

    test "falls back to the :os.type tuple when the file is missing" do
      assert SystemInfo.os("/does/not/exist") == SystemInfo.os_fallback()
    end
  end

  describe "os_fallback/0" do
    test "returns a family/name string" do
      {family, name} = :os.type()
      assert SystemInfo.os_fallback() == "#{family}/#{name}"
    end
  end

  describe "disk_free_mb_from/2" do
    test "picks the longest matching mount for the given path" do
      # Two mounts: / and /var. /var/lib/still must resolve against /var.
      entries = [
        {~c"/", 100_000_000, 50},
        {~c"/var", 20_000_000, 25}
      ]

      # /var mount: 20_000_000 KiB total, 25% used → 15_000_000 KiB free → 14648 MiB
      assert SystemInfo.disk_free_mb_from(entries, "/var/lib/still") == 14_648
    end

    test "returns nil when no mount matches the path" do
      entries = [{~c"/other", 1_000, 10}]
      assert SystemInfo.disk_free_mb_from(entries, "/var/lib/still") == nil
    end

    test "returns nil on an empty mount list" do
      assert SystemInfo.disk_free_mb_from([], "/var/lib/still") == nil
    end
  end
end
