defmodule HeddleIntegrations.SlackTest do
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

  describe "Slack" do
    @context %{
      "credential" => "main",
      "channel" => "#ops",
      "text" => "Hi {{name}}",
      "name" => "Ana"
    }

    test "posts with the token and fills in the message" do
      Req.Test.stub(HttpRequest, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:request, conn, Jason.decode!(raw)})
        Req.Test.json(conn, %{"ok" => true, "channel" => "C1", "ts" => "1.2"})
      end)

      assert {:ok, result, "success"} = Slack.SendMessage.handler(@context, nil)
      assert result["result"] == %{"channel" => "C1", "ts" => "1.2"}

      assert_received {:request, conn, %{"channel" => "#ops", "text" => "Hi Ana"}}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxb-1"]
    end

    test "takes the error output when Slack refuses it" do
      Req.Test.stub(
        HttpRequest,
        &Req.Test.json(&1, %{"ok" => false, "error" => "channel_not_found"})
      )

      assert {:ok, result, "error"} = Slack.SendMessage.handler(@context, nil)
      assert result["result"]["error"] =~ "channel_not_found"
    end

    test "takes the error output without a credential" do
      assert {:ok, result, "error"} = Slack.SendMessage.handler(%{"credential" => "nope"}, nil)
      assert result["result"]["error"] =~ "nope"
    end

    test "never puts the token in the result" do
      Req.Test.stub(HttpRequest, &Req.Test.json(&1, %{"ok" => true}))

      {:ok, result, "success"} = Slack.SendMessage.handler(@context, nil)

      refute inspect(result) =~ "xoxb-1"
    end

    test "replies in a thread when given one" do
      capture_slack(%{"ok" => true})

      context = Map.put(@context, "thread_ts", "1.1")

      assert {:ok, _context, "success"} = Slack.SendMessage.handler(context, nil)
      assert_received {:slack, conn, %{"thread_ts" => "1.1"}}
      assert conn.request_path == "/api/chat.postMessage"
    end

    test "updates, deletes and reacts to a message from the last step" do
      capture_slack(%{"ok" => true, "channel" => "C1", "ts" => "1.2"})

      context = %{
        "credential" => "main",
        "channel" => "{{result.channel}}",
        "ts" => "{{result.ts}}",
        "text" => "New",
        "emoji" => ":tada:",
        "result" => %{"channel" => "C1", "ts" => "1.2"}
      }

      assert {:ok, _context, "success"} = Slack.UpdateMessage.handler(context, nil)
      assert_received {:slack, conn, %{"channel" => "C1", "ts" => "1.2", "text" => "New"}}
      assert conn.request_path == "/api/chat.update"

      assert {:ok, _context, "success"} = Slack.DeleteMessage.handler(context, nil)
      assert_received {:slack, conn, %{"channel" => "C1", "ts" => "1.2"}}
      assert conn.request_path == "/api/chat.delete"

      assert {:ok, %{"result" => %{"emoji" => "tada"}}, "success"} =
               Slack.AddReaction.handler(context, nil)

      assert_received {:slack, conn, %{"name" => "tada", "timestamp" => "1.2"}}
      assert conn.request_path == "/api/reactions.add"
    end

    test "reads the messages of a channel" do
      message = %{"user" => "U1", "text" => "Hi", "ts" => "1.2", "blocks" => []}
      capture_slack(%{"ok" => true, "messages" => [message]})

      context = %{"credential" => "main", "channel" => "C1", "limit" => "5"}

      assert {:ok, %{"result" => [read]}, "success"} = Slack.ReadMessages.handler(context, nil)
      assert read == %{"user" => "U1", "text" => "Hi", "ts" => "1.2"}
      assert_received {:slack, conn, _body}
      assert conn.method == "GET"
      assert %{"channel" => "C1", "limit" => "5"} = URI.decode_query(conn.query_string)
    end

    test "lists the channels of every page" do
      Req.Test.stub(HttpRequest, fn conn ->
        case URI.decode_query(conn.query_string)["cursor"] do
          nil ->
            Req.Test.json(conn, %{
              "ok" => true,
              "channels" => [%{"id" => "C1", "name" => "a", "is_member" => true}],
              "response_metadata" => %{"next_cursor" => "next"}
            })

          "next" ->
            Req.Test.json(conn, %{"ok" => true, "channels" => [%{"id" => "C2", "name" => "b"}]})
        end
      end)

      assert {:ok, %{"result" => channels}, "success"} =
               Slack.ListChannels.handler(%{"credential" => "main"}, nil)

      assert channels == [%{"id" => "C1", "name" => "a"}, %{"id" => "C2", "name" => "b"}]
    end

    test "uploads a file a Download node returned, in Slack's three steps" do
      test = self()

      Req.Test.stub(HttpRequest, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:step, conn.request_path, conn.query_string, raw})

        case conn.request_path do
          "/api/files.getUploadURLExternal" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "upload_url" => "https://files.slack.com/upload/1",
              "file_id" => "F1"
            })

          "/upload/1" ->
            Plug.Conn.send_resp(conn, 200, "OK")

          "/api/files.completeUploadExternal" ->
            Req.Test.json(conn, %{"ok" => true})
        end
      end)

      context = %{
        "credential" => "main",
        "channel" => "C1",
        "filename" => "a.bin",
        "comment" => "Here",
        "content" => "{{result}}",
        "result" => %{"content" => "//4=", "encoding" => "base64"}
      }

      assert {:ok, %{"result" => %{"file_id" => "F1"}}, "success"} =
               UploadFile.handler(context, nil)

      assert_received {:step, "/api/files.getUploadURLExternal", query, ""}
      assert %{"filename" => "a.bin", "length" => "2"} = URI.decode_query(query)
      assert_received {:step, "/upload/1", "", <<255, 254>>}
      assert_received {:step, "/api/files.completeUploadExternal", "", raw}

      assert %{"channel_id" => "C1", "initial_comment" => "Here", "files" => [%{"id" => "F1"}]} =
               Jason.decode!(raw)
    end
  end
end
