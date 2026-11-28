defmodule HeddleIntegrations.AgentsTest do
  use ExUnit.Case, async: false

  alias Bobbin.TestHost
  alias HeddleIntegrations.Nodes.Agents.{Agent, Ask, Reply, SendMessage, SetState, Think}

  defmodule Model do
    @moduledoc "Stands in for ReqLLM: a test scripts the model's answers."
    def generate_text(model, context, options) do
      test = Application.fetch_env!(:heddle_jido, :test_pid)
      send(test, {:model, self(), model, context, options})
      Application.fetch_env!(:heddle_jido, :script).(context, options)
    end
  end

  setup do
    TestHost.reset()
    Application.put_env(:heddle_jido, :model_client, Model)
    Application.put_env(:heddle_jido, :test_pid, self())

    Application.put_env(:bobbin, :test_ai, %{
      model: {:openai, "gpt-test", []},
      options: [api_key: "secret"]
    })

    on_exit(fn ->
      Application.delete_env(:heddle_jido, :model_client)
      Application.delete_env(:bobbin, :test_ai)
      Application.delete_env(:bobbin, :test_start_runs)
    end)
  end

  defp script(fun), do: Application.put_env(:heddle_jido, :script, fun)

  defp answer(text, usage \\ %{input_tokens: 12, output_tokens: 3, total_cost: 0.001}) do
    response(ReqLLM.Context.assistant(text), :stop, usage)
  end

  defp call_tool(name, arguments) do
    tool_call = ReqLLM.ToolCall.new("c1", name, Jason.encode!(arguments))
    response(ReqLLM.Context.assistant("", tool_calls: [tool_call]), :tool_calls, %{})
  end

  defp response(message, finish, usage) do
    {:ok,
     %ReqLLM.Response{
       id: "r",
       model: "gpt-test",
       context: ReqLLM.Context.new([]),
       message: message,
       finish_reason: finish,
       usage: usage
     }}
  end

  @trigger %{
    "name" => "Ana",
    "instructions" => "You collect overdue invoices, kindly.",
    "credential" => "",
    "model" => "",
    "state" => ~s({"stage": "new", "attempts": 0})
  }

  defp start(data, trigger \\ @trigger) do
    context = Map.merge(trigger, %{"workspace_id" => 1, "run_id" => "run-1", "result" => data})
    {:ok, context, "exec"} = Agent.handler(context, nil)
    Map.drop(context, Map.keys(trigger))
  end

  defp think(context, message \\ "{{agent.message}}", tools \\ [], call \\ nil) do
    call = call || fn _name, _args -> {:error, "no tools"} end
    {:with_tools, fun} = Think.handler(Map.put(context, "message", message), nil)
    fun.(tools, call)
  end

  describe "Agent" do
    test "puts the agent of the message in the context" do
      context = start(%{"message" => "Hi", "key" => "c-42", "from" => %{"type" => "flow"}})

      assert %{"name" => "Ana", "key" => "c-42", "message" => "Hi"} = context["agent"]
      assert context["agent"]["state"] == %{"stage" => "new", "attempts" => 0}
      assert context["result"]["message"] == "Hi"
    end

    test "an instance keeps its state, and takes the fields the flow added since" do
      {:ok, _version} =
        TestHost.store_put(
          1,
          "agents",
          "Ana/c-42",
          %{"state" => %{"stage" => "late", "gone" => 1}},
          []
        )

      context = start(%{"message" => "Hi", "key" => "c-42"})

      assert context["agent"]["state"] == %{"stage" => "late", "attempts" => 0}
    end

    test "a field whose type changed starts over" do
      {:ok, _version} =
        TestHost.store_put(1, "agents", "Ana/main", %{"state" => %{"attempts" => "two"}}, [])

      assert start(%{})["agent"]["state"]["attempts"] == 0
    end

    test "without a key, the message goes to its only instance" do
      assert start(%{"message" => "Hi"})["agent"]["key"] == "main"
    end

    test "needs a name, and a state that is an object" do
      context = %{"workspace_id" => 1, "result" => %{}}

      assert {:error, "Give the agent a name."} =
               Agent.handler(Map.merge(@trigger, Map.put(context, "name", " ")), nil)

      assert {:error, "State must be a JSON object" <> _rest} =
               Agent.handler(Map.merge(@trigger, Map.put(context, "state", "[1]")), nil)
    end
  end

  describe "Agent: Think" do
    test "answers with the model the host gives, and keeps the conversation" do
      script(fn _context, _options -> answer("Hello, Bia!") end)
      context = start(%{"message" => "Hi, I'm Bia", "key" => "bia"})

      assert {:ok, %{"reply" => "Hello, Bia!"}} = think(context)

      assert_received {:model, _pid, _model, request, options}
      assert options[:api_key] == "secret"
      [system | _rest] = request.messages
      assert system.role == :system
      text = Enum.map_join(system.content, & &1.text)
      assert text =~ "You collect overdue invoices, kindly."
      assert text =~ "You are the agent Ana. This conversation is with bia."
      assert text =~ ~s("stage":"new")

      assert_received {:bobbin_usage, %{input_tokens: 12, output_tokens: 3}}

      {:ok, %{value: instance}} = TestHost.store_get(1, "agents", "Ana/bia")
      assert instance["messages"] == 1
      refute inspect(instance) =~ "secret"
    end

    test "the next message sees the conversation before it" do
      script(fn _context, _options -> answer("Hello, Bia!") end)
      {:ok, _reply} = think(start(%{"message" => "Hi, I'm Bia", "key" => "bia"}))

      script(fn _context, _options -> answer("You are Bia.") end)

      assert {:ok, %{"reply" => "You are Bia."}} =
               think(start(%{"message" => "Who am I?", "key" => "bia"}))

      assert_received {:model, _pid, _model, _first, _options}
      assert_received {:model, _pid, _model, second, _options}

      texts =
        for message <- second.messages, message.role in [:user, :assistant] do
          Enum.map_join(message.content, & &1.text)
        end

      assert texts == ["Hi, I'm Bia", "Hello, Bia!", "Who am I?"]
    end

    test "each instance has its own conversation" do
      script(fn _context, _options -> answer("Hello!") end)
      {:ok, _reply} = think(start(%{"message" => "Hi, I'm Bia", "key" => "bia"}))
      {:ok, _reply} = think(start(%{"message" => "Hi", "key" => "caio"}))

      assert_received {:model, _pid, _model, _first, _options}
      assert_received {:model, _pid, _model, second, _options}
      assert Enum.count(second.messages, &(&1.role == :user)) == 1
    end

    test "runs the tools in the node's process" do
      test = self()

      script(fn context, _options ->
        if Enum.any?(context.messages, &(&1.role == :tool)),
          do: answer("The invoice is paid."),
          else: call_tool("check_invoice", %{"id" => "F-7"})
      end)

      tools = [
        %{
          name: "check_invoice",
          description: "Reads an invoice",
          parameters: %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}
        }
      ]

      call = fn name, args ->
        send(test, {:tool, name, args, self() == test})
        {:ok, ~s({"status":"paid"})}
      end

      context = start(%{"message" => "Is F-7 paid?"})

      assert {:ok, %{"reply" => "The invoice is paid."}} =
               think(context, "{{agent.message}}", tools, call)

      assert_received {:tool, "check_invoice", %{"id" => "F-7"}, true}
    end

    test "says why it couldn't answer" do
      script(fn _context, _options -> {:error, "the provider is down"} end)

      assert {:error, "The agent could not answer: " <> _reason} =
               think(start(%{"message" => "Hi"}))

      assert {:error, %{reason: _}} = TestHost.store_get(1, "agents", "Ana/main") |> wrap()
    end

    test "says when there is no model" do
      Application.put_env(:bobbin, :test_ai, fn _context, _capability ->
        {:error, "Pick a model."}
      end)

      assert {:error, "Pick a model."} = think(start(%{"message" => "Hi"}))
    end

    test "needs the Agent trigger before it" do
      assert {:ok, %{"result" => %{"error" => "This node goes in an agent's flow" <> _}}, "error"} =
               Think.handler(%{"message" => "Hi"}, nil)
    end
  end

  defp wrap({:error, :not_found}), do: {:error, %{reason: :not_found}}
  defp wrap(other), do: other

  describe "Agent: Set State" do
    test "changes the state, kept for the next message" do
      context = start(%{"key" => "c-42"})

      assert {:ok, context, "success"} =
               SetState.handler(
                 Map.put(
                   context,
                   "changes",
                   ~s({"stage": "late", "attempts": {{agent.state.attempts}}})
                 ),
                 nil
               )

      assert context["result"] == %{"stage" => "late", "attempts" => 0}
      assert start(%{"key" => "c-42"})["agent"]["state"] == %{"stage" => "late", "attempts" => 0}
    end

    test "takes only the fields the agent keeps, with their type" do
      context = start(%{})

      assert {:ok, %{"result" => %{"error" => "mood isn't in the agent's state" <> _}}, "error"} =
               SetState.handler(Map.put(context, "changes", ~s({"mood": "happy"})), nil)

      assert {:ok, %{"result" => %{"error" => "attempts must be a number."}}, "error"} =
               SetState.handler(Map.put(context, "changes", ~s({"attempts": "two"})), nil)
    end
  end

  describe "Agent: Send Message" do
    test "starts a run of the agent's instance, in its lane" do
      context = %{
        "workspace_id" => 1,
        "flow_id" => 9,
        "run_id" => "run-9",
        "to" => "Ana",
        "key" => "c-42",
        "message" => "Invoice F-7 is late"
      }

      assert {:ok, %{"result" => %{"agent" => "Ana", "key" => "c-42"}}, "success"} =
               SendMessage.handler(context, nil)

      assert [request] = TestHost.runs()
      assert request.node_type == "Agent"
      assert request.match == %{"name" => "Ana"}
      assert request.lane == "agents:Ana/c-42"

      assert request.data == %{
               "message" => "Invoice F-7 is late",
               "key" => "c-42",
               "from" => %{"type" => "flow", "flow_id" => 9, "run_id" => "run-9"}
             }
    end

    test "an object goes as JSON, and an agent says who it is" do
      context =
        start(%{"key" => "c-42"})
        |> Map.merge(%{
          "to" => "Bob",
          "key" => "",
          "message" => "{{data}}",
          "data" => %{"id" => 7}
        })

      {:ok, _context, "success"} = SendMessage.handler(context, nil)
      [request] = TestHost.runs()
      assert request.data["message"] == ~s({"id":7})
      assert request.data["key"] == "main"
      assert request.data["from"] == %{"type" => "agent", "agent" => "Ana", "key" => "c-42"}
    end

    test "says when no flow is the agent" do
      Application.put_env(:bobbin, :test_start_runs, fn _request -> {:ok, []} end)

      assert {:ok, %{"result" => %{"error" => "No published flow is the agent Ana." <> _}},
              "error"} =
               SendMessage.handler(%{"workspace_id" => 1, "to" => "Ana", "message" => "Hi"}, nil)
    end
  end

  describe "Agent: Ask" do
    test "sends the message with where to reply, and waits" do
      context = %{
        "workspace_id" => 1,
        "run_id" => "run-9",
        "to" => "Ana",
        "message" => "Paid?",
        "timeout" => "60"
      }

      assert {:wait, %{"call" => true, "key" => key, "resume_at" => _at}} =
               Ask.handler(context, nil)

      [request] = TestHost.runs()
      assert request.data["reply_to"] == %{"run_id" => "run-9", "key" => key}
    end

    test "an agent can't ask itself" do
      context = start(%{}) |> Map.merge(%{"to" => "Ana", "message" => "Hi"})

      assert {:ok, %{"result" => %{"error" => "An agent can't ask itself." <> _}}, "error"} =
               Ask.handler(context, nil)
    end
  end

  describe "Agent: Reply" do
    test "resumes the run that asked" do
      context =
        start(%{"message" => "Paid?", "reply_to" => %{"run_id" => "run-9", "key" => "agents:k"}})

      assert {:ok, %{"result" => %{"reply" => "Yes", "answered" => true}}, "success"} =
               Reply.handler(Map.put(context, "message", "Yes"), nil)

      assert TestHost.resumed("run-9", "agents:k") ==
               {:ok, %{"reply" => "Yes", "agent" => "Ana", "key" => "main"}}
    end

    test "a message nobody waits for is not answered" do
      context = start(%{"message" => "FYI"})

      assert {:ok, %{"result" => %{"answered" => false}}, "success"} =
               Reply.handler(Map.put(context, "message", "Ok"), nil)
    end
  end
end
