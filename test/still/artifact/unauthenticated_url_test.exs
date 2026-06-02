defmodule Still.Artifact.UnauthenticatedURLTest do
  use ExUnit.Case, async: true

  alias Still.Artifact.Provider.URL

  describe "download/2" do
    test "writes the response body to the destination path on a 2xx" do
      dest = Path.join(System.tmp_dir!(), "still-url-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dest) end)

      Req.Test.stub(URL, fn conn ->
        Plug.Conn.send_resp(conn, 200, "tarball-contents")
      end)

      spec = %{artifact_url: "http://example.com/app.tar.gz"}
      assert :ok = URL.download(spec, dest)
      assert File.read!(dest) =~ "tarball-contents"
    end

    test "returns an error on non-2xx" do
      dest = Path.join(System.tmp_dir!(), "still-url-fail-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dest) end)

      Req.Test.stub(URL, fn conn ->
        Plug.Conn.send_resp(conn, 404, "not found")
      end)

      spec = %{artifact_url: "http://example.com/missing.tar.gz"}
      assert {:error, "download failed: HTTP 404"} = URL.download(spec, dest)
    end

    @tag :capture_log
    test "returns an error on transport failure" do
      dest = Path.join(System.tmp_dir!(), "still-url-err-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dest) end)

      Req.Test.stub(URL, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      spec = %{artifact_url: "http://example.com/app.tar.gz"}
      assert {:error, "download failed: " <> _} = URL.download(spec, dest)
    end
  end
end
