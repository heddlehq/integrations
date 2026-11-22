defmodule HeddleIntegrations.S3Test do
  use ExUnit.Case, async: false

  alias Bobbin.Service, as: Integration
  alias HeddleIntegrations.Slack.Slack
  alias HeddleIntegrations.Nodes.{Csv, Ftp, HttpRequest, S3}
  alias HeddleIntegrations.Nodes.Slack.UploadFile

  defmodule Vault do
    # Tells the test which workspace a run looked in.
    def fetch(workspace_id, name, kind) do
      send(self(), {:credential_workspace, workspace_id})
      fetch(name, kind)
    end

    def fetch("main", "slack"), do: {:ok, %{"token" => "xoxb-1"}}

    def fetch("aws", "s3") do
      {:ok, %{"access_key_id" => "AK", "secret_access_key" => "SK", "region" => "sa-east-1"}}
    end

    def fetch("minio", "s3") do
      {:ok,
       %{"access_key_id" => "AK", "secret_access_key" => "SK", "endpoint" => "http://m:9000/"}}
    end

    def fetch("down", "ftp") do
      {:ok, %{"host" => "127.0.0.1", "port" => "1", "username" => "u", "password" => "p"}}
    end

    def fetch(name, _kind), do: {:error, "no #{inspect(name)}"}
  end

  setup do
    previous = Application.get_env(:bobbin, :credentials_client)
    Application.put_env(:bobbin, :credentials_client, Vault)
    on_exit(fn -> Application.put_env(:bobbin, :credentials_client, previous) end)
  end

  defp capture_slack(reply) do
    Req.Test.stub(HttpRequest, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      send(self(), {:slack, conn, body})
      Req.Test.json(conn, reply)
    end)
  end

  describe "S3" do
    defp capture_s3(reply) do
      Req.Test.stub(HttpRequest, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:s3, conn, raw})
        reply.(conn)
      end)
    end

    test "signs the request and reads a file on AWS" do
      capture_s3(&Plug.Conn.send_resp(&1, 200, "hello"))

      context = %{
        "credential" => "aws",
        "bucket" => "b",
        "key" => "a b/c.txt"
      }

      assert {:ok, %{"result" => %{"content" => "hello"}}, "success"} =
               S3.Download.handler(context, nil)

      assert_received {:s3, conn, ""}
      assert conn.host == "b.s3.sa-east-1.amazonaws.com"
      assert conn.request_path == "/a%20b/c.txt"
      assert [auth] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth =~ "AWS4-HMAC-SHA256 Credential=AK/"
      refute auth =~ "SK"
    end

    test "keeps a binary file safe to save" do
      capture_s3(&Plug.Conn.send_resp(&1, 200, <<255, 254>>))

      context = %{"credential" => "aws", "bucket" => "b", "key" => "k"}

      assert {:ok, %{"result" => result}, "success"} = S3.Download.handler(context, nil)
      assert result == %{"content" => "//4=", "encoding" => "base64"}
    end

    test "puts the bucket in the path of a custom endpoint" do
      capture_s3(&Plug.Conn.send_resp(&1, 200, ""))

      context = %{
        "credential" => "minio",
        "bucket" => "b",
        "key" => "k",
        "content" => "{{x}}",
        "x" => "data"
      }

      assert {:ok, _context, "success"} = S3.Upload.handler(context, nil)
      assert_received {:s3, conn, "data"}
      assert conn.method == "PUT"
      assert conn.host == "m"
      assert conn.request_path == "/b/k"
    end

    test "lists keys" do
      xml = "<R><Contents><Key>a.txt</Key></Contents><Contents><Key>b&amp;c</Key></Contents></R>"
      capture_s3(&Plug.Conn.send_resp(&1, 200, xml))

      context = %{"credential" => "aws", "bucket" => "b", "prefix" => "x/"}

      assert {:ok, %{"result" => %{"keys" => ["a.txt", "b&c"]}}, "success"} =
               S3.List.handler(context, nil)

      assert_received {:s3, conn, ""}
      assert %{"list-type" => "2", "prefix" => "x/"} = URI.decode_query(conn.query_string)
    end

    test "takes the error output with what S3 said" do
      capture_s3(&Plug.Conn.send_resp(&1, 404, "<Error><Code>NoSuchKey</Code></Error>"))

      assert {:ok, %{"result" => %{"error" => message}}, "error"} =
               S3.Download.handler(%{"credential" => "aws", "bucket" => "b", "key" => "k"}, nil)

      assert message =~ "NoSuchKey"
    end

    test "uploads with the content type, and a file from a Download node intact" do
      capture_s3(&Plug.Conn.send_resp(&1, 200, ""))

      context = %{
        "credential" => "aws",
        "bucket" => "b",
        "key" => "k",
        "content" => "{{result}}",
        "content_type" => "image/png",
        "result" => %{"content" => "//4=", "encoding" => "base64"}
      }

      assert {:ok, _context, "success"} = S3.Upload.handler(context, nil)
      assert_received {:s3, conn, <<255, 254>>}
      assert Plug.Conn.get_req_header(conn, "content-type") == ["image/png"]
    end

    test "deletes a file" do
      capture_s3(&Plug.Conn.send_resp(&1, 204, ""))

      context = %{"credential" => "aws", "bucket" => "b", "key" => "k"}

      assert {:ok, %{"result" => %{"key" => "k"}}, "success"} = S3.Delete.handler(context, nil)
      assert_received {:s3, %{method: "DELETE"}, ""}
    end

    test "copies a file without reading it" do
      capture_s3(&Plug.Conn.send_resp(&1, 200, "<CopyObjectResult/>"))

      context = %{
        "credential" => "minio",
        "bucket" => "from",
        "key" => "a b.txt",
        "target_bucket" => "to",
        "target_key" => "c.txt"
      }

      assert {:ok, %{"result" => %{"key" => "c.txt"}}, "success"} = S3.Copy.handler(context, nil)
      assert_received {:s3, conn, ""}
      assert conn.method == "PUT"
      assert conn.request_path == "/to/c.txt"
      assert Plug.Conn.get_req_header(conn, "x-amz-copy-source") == ["/from/a%20b.txt"]
    end

    test "tells about a file without reading it" do
      capture_s3(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-length", "12")
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.put_resp_header("last-modified", "Fri, 06 Nov 2026 10:00:00 GMT")
        |> Plug.Conn.send_resp(200, "")
      end)

      context = %{"credential" => "aws", "bucket" => "b", "key" => "k"}

      assert {:ok, %{"result" => info}, "success"} = S3.Info.handler(context, nil)
      assert %{"size" => 12, "type" => "text/plain", "key" => "k"} = info
      assert_received {:s3, %{method: "HEAD"}, ""}
    end

    test "creates a link that expires, without the secret in it" do
      context = %{"credential" => "aws", "bucket" => "b", "key" => "a b", "expires" => "999999"}

      assert {:ok, %{"result" => %{"url" => url, "expires_in" => 604_800}}, "success"} =
               S3.ShareLink.handler(context, nil)

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert uri.host == "b.s3.sa-east-1.amazonaws.com"
      assert uri.path == "/a%20b"
      assert query["X-Amz-Expires"] == "604800"
      assert query["X-Amz-Signature"]
      refute url =~ "SK"
    end
  end
end
