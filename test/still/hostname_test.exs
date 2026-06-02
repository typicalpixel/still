defmodule Still.HostnameTest do
  use ExUnit.Case, async: true

  alias Still.Hostname

  describe "valid?/1" do
    test "accepts IPv4 addresses" do
      for ip <- ["10.0.0.5", "127.0.0.1", "192.168.1.1", "255.255.255.255", "0.0.0.0"] do
        assert Hostname.valid?(ip), "expected #{ip} to be valid"
      end
    end

    test "accepts IPv6 addresses" do
      for ip <- ["::1", "2001:db8::1", "fe80::1", "::"] do
        assert Hostname.valid?(ip), "expected #{ip} to be valid"
      end
    end

    test "accepts hostnames and FQDNs" do
      for host <- ["app1", "server.example.com", "box.tail-scale.ts.net", "a.b.c.d.example"] do
        assert Hostname.valid?(host), "expected #{host} to be valid"
      end
    end

    test "rejects strings with spaces" do
      refute Hostname.valid?("not a host")
      refute Hostname.valid?("host with spaces")
    end

    test "rejects strings with path/query/fragment characters" do
      refute Hostname.valid?("host/admin")
      refute Hostname.valid?("host?q=1")
      refute Hostname.valid?("host#frag")
    end

    test "rejects bracketed IPv6 (the bare form should be used)" do
      refute Hostname.valid?("[::1]")
    end

    test "rejects the empty string" do
      refute Hostname.valid?("")
    end
  end
end
