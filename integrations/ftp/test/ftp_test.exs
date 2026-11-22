defmodule HeddleIntegrations.FTPTest do
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

  describe "FTP" do
    test "takes the error output when the server can't be reached" do
      assert {:ok, %{"result" => %{"error" => message}}, "error"} =
               Ftp.Download.handler(%{"credential" => "down", "path" => "a"}, nil)

      assert is_binary(message)
    end

    test "takes the error output without a credential" do
      assert {:ok, _context, "error"} = Ftp.List.handler(%{"credential" => "nope"}, nil)
    end
  end
end
