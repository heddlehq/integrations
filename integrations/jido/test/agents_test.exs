defmodule HeddleIntegrations.AgentsTest do
  use ExUnit.Case, async: false

  alias Bobbin.TestHost
  alias HeddleIntegrations.Nodes.Agents.{Agent, Ask, Reply, SendMessage, SetState, Think}

  alias HeddleIntegrations.Nodes.Agents.{
    CancelSchedule,
    EndInstance,
    Event,
    ListInstances,
    Pause,
    PublishEvent,
    ReadAgent,
    ResetInstance,
    Schedule
  }

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
               "from" => %{"type" => "flow", "flow_id" => 9, "run_id" => "run-9"},
               "depth" => 1
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

  defp resume(context, resumed, tools \\ [], call \\ nil) do
    call = call || fn _name, _args -> {:error, "no tools"} end
    {:with_tools, fun} = Think.handler(Map.put(context, "resumed", resumed), nil)
    fun.(tools, call)
  end

  @refund %{
    name: "refund",
    description: "Refunds an order",
    parameters: %{"type" => "object", "properties" => %{"order" => %{"type" => "string"}}}
  }

  describe "Agent: Think, waiting" do
    test "a tool that needs approval waits, and runs once a person approves" do
      test = self()

      script(fn context, _options ->
        cond do
          Enum.any?(context.messages, &(text_of(&1) =~ "approved refund")) -> answer("Refunded!")
          Enum.any?(context.messages, &(&1.role == :tool)) -> answer("Waiting for approval.")
          true -> call_tool("refund", %{"order" => "A-1"})
        end
      end)

      call = fn name, args ->
        send(test, {:ran, name, args})
        {:ok, ~s({"refunded":true})}
      end

      context = start(%{"message" => "Refund A-1"})
      context = Map.put(context, "approval", "refund")

      assert {:wait, wait} = think(context, "{{agent.message}}", [@refund], call)
      assert wait["approval"]["title"] == "Ana: refund?"
      assert wait["again"] == true

      assert wait["data"] == %{
               "kind" => "approval",
               "tool" => "refund",
               "arguments" => %{"order" => "A-1"}
             }

      refute_received {:ran, _name, _args}

      resumed = %{
        "by" => "call",
        "request" => %{"decision" => "approved", "by" => "bia@x.com"},
        "wait" => wait
      }

      assert {:ok, %{"reply" => "Refunded!"}} = resume(context, resumed, [@refund], call)
      assert_received {:ran, "refund", %{"order" => "A-1"}}

      {:ok, %{value: instance}} = TestHost.store_get(1, "agents", "Ana/main")
      assert Enum.map(instance["transcript"], & &1["text"]) == ["Refund A-1", "Refunded!"]
    end

    test "a rejected tool doesn't run" do
      script(fn context, _options ->
        cond do
          Enum.any?(context.messages, &(text_of(&1) =~ "rejected refund")) ->
            answer("Ok, no refund.")

          Enum.any?(context.messages, &(&1.role == :tool)) ->
            answer("Waiting.")

          true ->
            call_tool("refund", %{"order" => "A-1"})
        end
      end)

      call = fn _name, _args -> flunk("the tool ran") end
      context = start(%{"message" => "Refund A-1"}) |> Map.put("approval", "refund")
      {:wait, wait} = think(context, "{{agent.message}}", [@refund], call)

      resumed = %{"by" => "call", "request" => %{"decision" => "rejected"}, "wait" => wait}
      assert {:ok, %{"reply" => "Ok, no refund."}} = resume(context, resumed, [@refund], call)
    end

    test "asks another agent, waits for its reply, and goes on with it" do
      script(fn context, _options ->
        cond do
          Enum.any?(context.messages, &(text_of(&1) =~ "Bob replied to your question: 42")) ->
            answer("Bob says 42.")

          Enum.any?(context.messages, &(&1.role == :tool)) ->
            answer("Waiting for Bob.")

          true ->
            call_tool("ask_agent", %{"agent" => "Bob", "question" => "How many?"})
        end
      end)

      context = start(%{"message" => "Ask Bob"}) |> Map.put("agents", "Bob")

      assert {:wait, %{"call" => true, "key" => key, "again" => true} = wait} = think(context)
      assert [request] = TestHost.runs()
      assert request.match == %{"name" => "Bob"}
      assert request.data["message"] == "How many?"
      assert request.data["reply_to"] == %{"run_id" => "run-1", "key" => key}
      assert request.data["waiting"] == ["Ana/main"]

      resumed = %{"by" => "call", "request" => %{"reply" => "42"}, "wait" => wait}
      assert {:ok, %{"reply" => "Bob says 42."}} = resume(context, resumed)
    end

    test "can't ask back an agent that waits for it" do
      context =
        start(%{"message" => "Hi", "waiting" => ["Bob/main"]})
        |> Map.merge(%{"to" => "Bob", "message" => "Hi"})

      assert {:ok, %{"result" => %{"error" => "Bob is waiting for an answer" <> _}}, "error"} =
               Ask.handler(context, nil)
    end

    test "remembers a field of its state, with its type" do
      script(fn context, _options ->
        if Enum.any?(context.messages, &(&1.role == :tool)),
          do: answer("Noted."),
          else: call_tool("remember", %{"field" => "attempts", "value" => "3"})
      end)

      assert {:ok, %{"reply" => "Noted."}} = think(start(%{"message" => "I tried 3 times"}))
      assert start(%{})["agent"]["state"] == %{"stage" => "new", "attempts" => 3}
    end

    test "a long conversation becomes a summary, and the latest messages stay" do
      script(fn context, _options ->
        system = context.messages |> List.first() |> text_of()

        cond do
          system =~ "You summarize a conversation" -> answer("Bia owes F-7.")
          true -> answer("ok")
        end
      end)

      for n <- 1..16, do: {:ok, _reply} = think(start(%{"message" => "message #{n}"}))

      {:ok, %{value: instance}} = TestHost.store_get(1, "agents", "Ana/main")
      assert instance["summary"] == "Bia owes F-7."
      assert length(instance["transcript"]) <= 30
      assert instance["messages"] == 16

      script(fn _context, _options -> answer("ok") end)
      {:ok, _reply} = think(start(%{"message" => "and now?"}))
      assert_received {:model, _pid, _model, _request, _options}
      flush_models()
    end
  end

  defp flush_models do
    receive do
      {:model, _pid, _model, _request, _options} -> flush_models()
    after
      0 -> :ok
    end
  end

  defp text_of(%{content: content}) when is_list(content),
    do: Enum.map_join(content, &(&1.text || ""))

  defp text_of(_message), do: ""

  describe "limits" do
    test "an instance takes so many messages an hour" do
      trigger = Map.put(@trigger, "max_messages", "2")

      context =
        Map.merge(trigger, %{"workspace_id" => 1, "run_id" => "r", "result" => %{"key" => "k"}})

      assert {:ok, _context, "exec"} = Agent.handler(context, nil)
      assert {:ok, _context, "exec"} = Agent.handler(context, nil)
      assert {:error, "Ana got 2 messages for k this hour" <> _} = Agent.handler(context, nil)
    end

    test "an instance spends so much a day" do
      trigger = Map.put(@trigger, "max_cost", "0.5")
      context = Map.merge(trigger, %{"workspace_id" => 1, "run_id" => "r", "result" => %{}})

      :ok = HeddleIntegrations.Services.Agents.spend_cost(1, "Ana", "main", 0.6)
      assert {:error, "Ana spent its $0.5 for main today" <> _} = Agent.handler(context, nil)
    end

    test "Think counts what the model cost" do
      script(fn _context, _options ->
        answer("Hi", %{input_tokens: 1, output_tokens: 1, total_cost: 0.25})
      end)

      {:ok, _reply} = think(start(%{"message" => "Hi"}))
      assert HeddleIntegrations.Services.Agents.budget(1, "Ana", "main")["cost"] == 0.25
    end

    test "only who it allows may message it" do
      trigger = Map.put(@trigger, "allowed", "chat, Bob")
      base = Map.merge(trigger, %{"workspace_id" => 1, "run_id" => "r"})

      ok = fn from -> Agent.handler(Map.put(base, "result", %{"from" => from}), nil) end

      assert {:ok, _context, "exec"} = ok.(%{"type" => "chat"})
      assert {:ok, _context, "exec"} = ok.(%{"type" => "agent", "agent" => "bob"})
      assert {:ok, _context, "exec"} = ok.(%{"type" => "schedule"})

      assert {:error, "Ana doesn't take messages from the flow 3." <> _} =
               ok.(%{"type" => "flow", "flow_id" => 3})
    end

    test "a chain of agents stops five messages deep" do
      context =
        start(%{"message" => "Hi", "depth" => 5})
        |> Map.merge(%{"to" => "Bob", "message" => "Hi"})

      assert {:ok, %{"result" => %{"error" => "Agents messaged each other 5 times" <> _}},
              "error"} =
               SendMessage.handler(context, nil)
    end

    test "a paused agent takes no messages, until resumed" do
      flow = %{
        "workspace_id" => 1,
        "run_id" => "r",
        "to" => "Ana",
        "key" => "",
        "action" => "pause"
      }

      assert {:ok, %{"result" => %{"paused" => true}}, "success"} = Pause.handler(flow, nil)

      assert {:ok, %{"result" => %{"error" => "The agent Ana is paused." <> _}}, "error"} =
               SendMessage.handler(Map.merge(flow, %{"message" => "Hi"}), nil)

      context = Map.merge(@trigger, %{"workspace_id" => 1, "result" => %{}})
      assert {:error, "The agent Ana is paused" <> _} = Agent.handler(context, nil)

      {:ok, _context, "success"} = Pause.handler(Map.put(flow, "action", "resume"), nil)

      assert {:ok, _context, "success"} =
               SendMessage.handler(Map.merge(flow, %{"message" => "Hi"}), nil)
    end
  end

  describe "schedules" do
    test "a message for later, shown in the instance, and called off" do
      context =
        start(%{"key" => "c-1"})
        |> Map.merge(%{
          "message" => "Paid yet?",
          "in" => "3",
          "unit" => "days",
          "at" => "",
          "key" => ""
        })

      assert {:ok, %{"result" => %{"id" => id, "at" => at, "key" => "c-1"}}, "success"} =
               Schedule.handler(context, nil)

      [request] = TestHost.runs()
      assert request.lane == "agents:Ana/c-1"
      assert request.data["schedule"] == id
      assert request.data["depth"] == 0
      assert request.data["from"] == %{"type" => "schedule"}
      assert DateTime.diff(request.at, DateTime.utc_now()) in (3 * 86_400 - 5)..(3 * 86_400)
      {:ok, _at, _offset} = DateTime.from_iso8601(at)

      [%{"id" => ^id}] =
        start(%{"key" => "c-1"})["agent"]
        |> then(fn _ ->
          HeddleIntegrations.Services.Agents.instance(%{"workspace_id" => 1}, "Ana", "c-1")[
            "schedules"
          ]
        end)

      assert {:ok, %{"result" => %{"cancelled" => [^id]}}, "success"} =
               CancelSchedule.handler(Map.put(start(%{"key" => "c-1"}), "id", ""), nil)

      assert TestHost.runs() == []
    end

    test "the message that comes is no longer scheduled" do
      context =
        start(%{"key" => "c-1"})
        |> Map.merge(%{
          "message" => "Later",
          "in" => "1",
          "unit" => "hours",
          "at" => "",
          "key" => ""
        })

      {:ok, %{"result" => %{"id" => id}}, "success"} = Schedule.handler(context, nil)

      start(%{"key" => "c-1", "schedule" => id, "from" => %{"type" => "schedule"}})

      assert HeddleIntegrations.Services.Agents.instance(%{"workspace_id" => 1}, "Ana", "c-1")[
               "schedules"
             ] == []
    end

    test "a new message moves the follow-up, and a follow-up doesn't schedule another" do
      fields = %{
        "message" => "Follow up",
        "in" => "3",
        "unit" => "days",
        "at" => "",
        "key" => "",
        "replace" => "true",
        "not_scheduled" => "true"
      }

      {:ok, %{"result" => %{"id" => first}}, "success"} =
        Schedule.handler(Map.merge(start(%{"key" => "l-1"}), fields), nil)

      {:ok, %{"result" => %{"id" => second}}, "success"} =
        Schedule.handler(Map.merge(start(%{"key" => "l-1"}), fields), nil)

      assert [%{"id" => ^second}] =
               HeddleIntegrations.Services.Agents.instance(%{"workspace_id" => 1}, "Ana", "l-1")[
                 "schedules"
               ]

      assert first != second
      assert [%{data: %{"schedule" => ^second}}] = TestHost.runs()

      follow_up =
        start(%{"key" => "l-1", "schedule" => second, "from" => %{"type" => "schedule"}})

      assert {:ok, %{"result" => %{"skipped" => true}}, "success"} =
               Schedule.handler(Map.merge(follow_up, fields), nil)
    end

    test "a follow-up's reply shows on the instance's chat" do
      {:ok, _runs} = Agent.chat_message(1, %{"name" => "Ana"}, "v1", "Oi")
      follow_up = start(%{"key" => "v1", "from" => %{"type" => "schedule"}})

      assert {:ok, %{"result" => %{"answered" => true}}, "success"} =
               Reply.handler(Map.put(follow_up, "message", "Still there?"), nil)

      assert [_visitor, %{role: :agent, text: "Still there?"}] =
               Agent.chat_history(1, %{"name" => "Ana"}, "v1")
    end

    test "says when the time is wrong" do
      context =
        start(%{}) |> Map.merge(%{"message" => "x", "in" => "0", "unit" => "days", "at" => ""})

      assert {:ok, %{"result" => %{"error" => "In must be a number" <> _}}, "error"} =
               Schedule.handler(context, nil)

      context = Map.put(context, "at", "2001-01-01T00:00:00Z")

      assert {:ok, %{"result" => %{"error" => "At is in the past" <> _}}, "error"} =
               Schedule.handler(context, nil)
    end
  end

  describe "events" do
    test "publishing starts the flows that wait for it, and for any event" do
      context =
        start(%{"key" => "c-1"})
        |> Map.merge(%{"event" => "deal.won", "data" => ~s({"value": 10})})

      assert {:ok, %{"result" => %{"event" => "deal.won"}}, "success"} =
               PublishEvent.handler(context, nil)

      assert [named, any] = TestHost.runs()
      assert named.node_type == "Agent Event"
      assert named.match == %{"event" => "deal.won"}
      assert any.match == %{"event" => ""}
      assert named.data["agent"] == "Ana"
      assert named.data["key"] == "c-1"
      assert named.data["data"] == %{"value" => 10}
    end

    test "the event trigger gives what was published, and how deep the chain is" do
      context = %{
        "event" => "",
        "result" => %{"event" => "deal.won", "data" => %{}, "agent" => "Ana", "depth" => 2}
      }

      assert {:ok, context, "exec"} = Event.handler(context, nil)
      assert context["result"]["agent"] == "Ana"
      assert context["agent_depth"] == 2
    end
  end

  describe "instances" do
    setup do
      {:ok, _} =
        TestHost.store_put(
          1,
          "agents",
          "Ana/a",
          %{"state" => %{"stage" => "won"}, "messages" => 2},
          []
        )

      {:ok, _} =
        TestHost.store_put(
          1,
          "agents",
          "Ana/b",
          %{"state" => %{"stage" => "new"}, "messages" => 1},
          []
        )

      {:ok, _} = TestHost.store_put(1, "agents", "Anabel/x", %{"state" => %{}}, [])
      :ok
    end

    test "reads an instance" do
      context = %{"workspace_id" => 1, "to" => "Ana", "key" => "a"}

      assert {:ok,
              %{"result" => %{"exists" => true, "state" => %{"stage" => "won"}, "messages" => 2}},
              "success"} =
               ReadAgent.handler(context, nil)

      assert {:ok, %{"result" => %{"exists" => false}}, "success"} =
               ReadAgent.handler(%{context | "key" => "zzz"}, nil)
    end

    test "lists an agent's instances only" do
      context = %{"workspace_id" => 1, "to" => "Ana", "prefix" => "", "limit" => ""}

      assert {:ok,
              %{"result" => %{"count" => 2, "instances" => [%{"key" => "a"}, %{"key" => "b"}]}},
              "success"} =
               ListInstances.handler(context, nil)
    end

    test "reset and end forget an instance" do
      assert {:ok, %{"result" => %{"existed" => true}}, "success"} =
               ResetInstance.handler(%{"workspace_id" => 1, "to" => "Ana", "key" => "a"}, nil)

      assert {:error, :not_found} = TestHost.store_get(1, "agents", "Ana/a", [])

      context = start(%{"key" => "b"})
      assert {:ok, %{"result" => %{"key" => "b"}}, "success"} = EndInstance.handler(context, nil)
      assert {:error, :not_found} = TestHost.store_get(1, "agents", "Ana/b", [])
    end
  end

  describe "chat and panel" do
    test "a person's message starts a run, and the reply shows in the chat" do
      controls = %{"name" => "Ana"}
      assert {:ok, _runs} = Agent.chat_message(1, controls, "chat:v1", "Oi")

      [request] = TestHost.runs()
      assert request.data["key"] == "chat:v1"
      assert request.data["from"] == %{"type" => "chat", "conversation" => "chat:v1"}
      assert [%{role: :visitor, text: "Oi"}] = Agent.chat_history(1, controls, "chat:v1")

      context = start(request.data)
      {:ok, _context, "success"} = Reply.handler(Map.put(context, "message", "Olá!"), nil)

      assert [%{role: :visitor}, %{role: :agent, text: "Olá!"}] =
               Agent.chat_history(1, controls, "chat:v1")

      assert Agent.chat_history(1, controls, "chat:v2") == []
    end

    test "a message that can't go isn't kept" do
      Application.put_env(:bobbin, :test_start_runs, fn _request -> {:ok, []} end)

      assert {:error, "No published flow is the agent Ana." <> _} =
               Agent.chat_message(1, %{"name" => "Ana"}, "c", "Oi")

      assert Agent.chat_history(1, %{"name" => "Ana"}, "c") == []
    end

    test "the drawer shows the instances and what is scheduled" do
      context =
        start(%{"key" => "c-1"})
        |> Map.merge(%{
          "message" => "Later",
          "in" => "1",
          "unit" => "days",
          "at" => "",
          "key" => ""
        })

      {:ok, _context, "success"} = Schedule.handler(context, nil)

      [instances, scheduled] = Agent.panel(1, %{"name" => "Ana"})
      assert instances.title == "Instances"
      assert [%{"Key" => "c-1"}] = instances.rows
      assert scheduled.title == "Scheduled"
      assert [%{"Message" => "Later"}] = scheduled.rows

      assert [%{text: "Give the agent a name" <> _}] = Agent.panel(1, %{"name" => ""})
    end
  end
end
