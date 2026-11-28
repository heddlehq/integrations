defmodule HeddleIntegrations.Nodes.Agents.Think do
  @moduledoc """
  The agent works on the message with its model, using the nodes connected to `tools`,
  and answers. It remembers the conversation of its instance: the last messages go
  with each new one, and older ones as a summary. `result.reply` is what it said.

  Besides the nodes connected to `tools`, it can:

    * **remember** a field of its state, when the Agent trigger declares one.
    * **ask another agent**, of those listed in Agents it can ask. The run waits for the
      reply, holding no worker, and the agent goes on with it.
    * wait for **a person's approval** before a tool listed in Tools that need approval.
      The run waits on the Approvals page, and the tool runs only once approved.

  The reasoning is Jido's ReAct, see `HeddleIntegrations.Agents.Brain`.
  """

  use Bobbin.Node

  alias Bobbin.Host
  alias Bobbin.Service
  alias HeddleIntegrations.Agents.Brain
  alias HeddleIntegrations.Agents.Bridge
  alias HeddleIntegrations.Nodes.Agents.Ask
  alias HeddleIntegrations.Services.Agents

  # The messages of the conversation that go with a new one.
  @window 20
  # How many messages are kept as they were before the older ones become a summary.
  @kept 10
  # How long an agent waits for another one's reply, in seconds.
  @ask_timeout 300
  @pending {__MODULE__, :pending}

  definition do
    Agents.definition(
      "Think",
      "The agent answers the message with its model, and can use the nodes connected to tools, ask other agents, and wait for approval.",
      [
        Agents.message_field("{{agent.message}}"),
        %{type: :text, name: :agents, label: "Agents it can ask", default: ""},
        %{type: :text, name: :approval, label: "Tools that need approval", default: ""}
      ],
      ["success", "error", "tools"]
    )
  end

  @impl true
  def handler(context, _input) do
    case Agents.agent(context) do
      {:ok, agent} ->
        {:with_tools, fn tools, call -> work(context, agent, tools, call) end}

      {:error, message} ->
        Service.failure(context, message)
    end
  end

  defp work(%{"resumed" => resumed} = context, agent, tools, call) do
    case note(resumed, call) do
      {:ok, message} -> think(context, agent, tools, call, message)
      {:error, message} -> {:error, message}
    end
  end

  defp work(context, agent, tools, call) do
    case Agents.text(context, "message") do
      "" -> {:error, "The message is empty."}
      message -> think(context, agent, tools, call, message)
    end
  end

  # What the agent is told when a wait ends: what the person decided, or what the
  # other agent said.
  defp note(%{"wait" => %{"data" => %{"kind" => "approval"} = pending}} = resumed, call) do
    tool = pending["tool"]

    case decision(resumed) do
      {:approved, by} ->
        case call.(tool, pending["arguments"] || %{}) do
          {:ok, output} ->
            {:ok,
             "[#{by} approved #{tool}. It ran and returned: #{output}] You are no longer waiting. Go on with the task, and answer the one you talk to."}

          {:error, message} ->
            {:ok,
             "[#{by} approved #{tool}, but it failed: #{message}] Go on, and say so if it matters."}
        end

      {:rejected, by, comment} ->
        why = if comment in [nil, ""], do: "", else: ", saying: #{comment}"

        {:ok,
         "[#{by} rejected #{tool}#{why}. It did not run, so don't do it.] Go on, and tell who you talk to if it matters."}

      :timeout ->
        {:ok, "[Nobody approved #{tool} in time, so it did not run.] Go on without it."}
    end
  end

  defp note(%{"wait" => %{"data" => %{"kind" => "ask"} = pending}} = resumed, _call) do
    case resumed do
      %{"by" => "call", "request" => %{"reply" => reply}} ->
        {:ok,
         "[#{pending["agent"]} replied to your question: #{reply}] You are no longer waiting. " <>
           "Answer the one you talk to now, with what #{pending["agent"]} said. Ask again only if it asked you something you can answer."}

      _timeout ->
        {:ok,
         "[#{pending["agent"]} didn't reply in time.] You are no longer waiting. Answer without it."}
    end
  end

  defp note(_resumed, _call), do: {:error, "The agent woke up without knowing why."}

  @approved ~w(approve approved yes true 1)

  defp decision(%{"by" => "call", "request" => request}) when is_map(request) do
    given =
      request["decision"] || get_in(request, ["body", "decision"]) ||
        get_in(request, ["query_params", "decision"])

    by = request["by"] || "A person"

    normalized = given |> to_string() |> String.trim() |> String.downcase()

    if normalized in @approved,
      do: {:approved, by},
      else: {:rejected, by, request["comment"] || get_in(request, ["body", "comment"])}
  end

  defp decision(_resumed), do: :timeout

  defp think(context, agent, tools, call, message) do
    ai =
      %{"workspace_id" => context["workspace_id"]}
      |> Map.merge(Map.take(agent, ~w(credential model)))

    Process.delete(@pending)
    spent = Bridge.spent()

    with {:ok, connection} <- Host.ai_connection(ai, :text),
         instance = Agents.instance(context, agent["name"], agent["key"]),
         {:ok, brain} <- brain(agent, instance),
         {:ok, signal} <- request(agent, instance, message, connection),
         {:ok, next, reply} <- reason(context, agent, brain, signal, tools, connection, call),
         pending = Process.delete(@pending),
         {:ok, _instance} <-
           keep(context, agent, next, instance, message, reply, pending, connection) do
      _spent =
        Agents.spend_cost(
          context["workspace_id"],
          agent["name"],
          agent["key"],
          Bridge.spent() - spent
        )

      case pending do
        nil -> {:ok, %{"reply" => reply}}
        pending -> wait(context, agent, pending)
      end
    end
  end

  # The instance's Jido agent, with the conversation it had.
  defp brain(agent, instance) do
    state =
      case instance["session"] do
        session when is_map(session) -> [state: %{session: Jido.Session.decode!(session)}]
        _none -> []
      end

    Brain.instantiate([id: brain_id(agent)] ++ state)
  rescue
    _error -> Brain.instantiate(id: brain_id(agent))
  end

  defp brain_id(agent), do: "#{agent["name"]}/#{agent["key"]}"

  defp request(agent, instance, message, connection) do
    Brain.request_signal(%{
      input: message,
      instructions: instructions(agent, instance),
      model: model_name(connection.model),
      context: %{max_messages: @window}
    })
  end

  defp instructions(agent, instance) do
    who = "You are the agent #{agent["name"]}. This conversation is with #{agent["key"]}."

    state =
      if agent["state"] == %{},
        do: "",
        else: "\n\nWhat you know (your state), as JSON: #{Jason.encode!(agent["state"])}"

    summary =
      case instance["summary"] do
        text when is_binary(text) and text != "" ->
          "Earlier in this conversation (a summary): " <> text

        _none ->
          nil
      end

    recent =
      case instance["recent"] do
        [_ | _] = messages ->
          "The messages before the ones you see:\n" <>
            Enum.map_join(messages, "\n", &"#{&1["role"]}: #{&1["text"]}")

        _none ->
          nil
      end

    [agent["instructions"], who <> state, summary, recent]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # Jido wants a model name as text, for what it knows about it. The call itself goes
  # with the connection Heddle gave, see Bridge.
  defp model_name({provider, name, _options}) when is_binary(name), do: "#{provider}:#{name}"
  defp model_name(%{provider: provider, id: id}), do: "#{provider}:#{id}"
  defp model_name(name) when is_binary(name), do: name
  defp model_name(_other), do: "openai:gpt-4o-mini"

  defp reason(context, agent, brain, signal, tools, connection, call) do
    all_tools = tools ++ own_tools(context, agent)

    jido = %{
      jido_ai_inference_client: Brain.Model,
      jido_ai_tool_sources: [{Brain.Tools, %{tools: all_tools}}]
    }

    fun = fn -> Brain.cmd(brain, signal, context: jido) end

    case Bridge.run(fun, connection, tool_call(context, agent, call)) do
      {:ok, next, directives} -> reply(next, directives)
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "The agent could not answer: #{inspect(reason)}"}
      other -> {:error, "The agent could not answer: #{inspect(other)}"}
    end
  end

  # The tools every agent has: to remember a field of its state, and to ask the
  # agents it may.
  defp own_tools(context, agent) do
    remember =
      case Map.keys(agent["declared"] || %{}) do
        [] ->
          []

        fields ->
          [
            %{
              name: "remember",
              description:
                "Keeps a fact in your state, for the next messages. Write the value as text; numbers and true/false are read as such.",
              parameters: %{
                "type" => "object",
                "properties" => %{
                  "field" => %{"type" => "string", "enum" => Enum.sort(fields)},
                  "value" => %{"type" => "string"}
                },
                "required" => ["field", "value"]
              }
            }
          ]
      end

    ask =
      case Agents.names(context, "agents") do
        [] ->
          []

        agents ->
          [
            %{
              name: "ask_agent",
              description:
                "Asks another agent a question and waits for its reply, which comes to you as a new message. Put everything it needs in the question. After calling it, stop and say in one short sentence that you are waiting.",
              parameters: %{
                "type" => "object",
                "properties" => %{
                  "agent" => %{"type" => "string", "enum" => agents},
                  "question" => %{"type" => "string"},
                  "key" => %{
                    "type" => "string",
                    "description" =>
                      "Which of its instances, like a customer id. Leave it out for its main one."
                  }
                },
                "required" => ["agent", "question"]
              }
            }
          ]
      end

    remember ++ ask
  end

  # Runs in the node's process, see Bridge. Once the agent waits for something, no
  # other tool runs before it comes.
  defp tool_call(context, agent, call) do
    approval = Agents.names(context, "approval")

    fn name, arguments ->
      arguments = arguments || %{}

      cond do
        Process.get(@pending) ->
          {:ok, "Stop here: you are waiting. Say in one short sentence what you are waiting for."}

        name == "remember" ->
          remember(context, agent, arguments)

        name == "ask_agent" ->
          ask_later(context, arguments)

        name in approval ->
          Process.put(@pending, %{"kind" => "approval", "tool" => name, "arguments" => arguments})

          {:ok,
           "This needs a person's approval first, and it is asked for now. Stop here and say in one short sentence that you are waiting for approval."}

        true ->
          call.(name, arguments)
      end
    end
  end

  defp remember(context, agent, %{"field" => field} = arguments) do
    current = Agents.current_state(context, agent)
    declared = agent["declared"] || %{}
    value = Agents.coerce(declared[field], arguments["value"])

    with {:ok, state} <- Agents.change_state(current, declared, %{field => value}),
         {:ok, _instance} <- Agents.update_instance(context, agent, %{"state" => state}) do
      {:ok, "Remembered: #{field} is #{Jason.encode!(value)}."}
    end
  end

  defp remember(_context, _agent, _arguments), do: {:error, "Say which field to remember."}

  defp ask_later(context, %{"agent" => name, "question" => question} = arguments) do
    if name in Agents.names(context, "agents") do
      Process.put(@pending, %{
        "kind" => "ask",
        "agent" => name,
        "key" => Agents.key(arguments["key"]),
        "question" => question
      })

      {:ok,
       "The question goes to #{name} now. Stop here and say in one short sentence that you are waiting for #{name}."}
    else
      {:error,
       "You can't ask #{name}. Ask one of: #{Enum.join(Agents.names(context, "agents"), ", ")}."}
    end
  end

  defp ask_later(_context, _arguments), do: {:error, "Say which agent to ask, and what."}

  defp reply(next, directives) do
    case Enum.find_value(directives, &reply_data/1) do
      %{status: :completed, output: output} ->
        {:ok, next, text(output)}

      %{reason: reason} when not is_nil(reason) ->
        {:error, "The agent could not answer: #{describe(reason)}"}

      _other ->
        {:error, "The agent ended without an answer."}
    end
  end

  defp reply_data(%{signal: %{data: %{status: _status} = data}}), do: data
  defp reply_data(_directive), do: nil

  defp text(output) when is_binary(output), do: output
  defp text(output), do: Jason.encode!(output)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{message: message}) when is_binary(message), do: message
  defp describe(reason), do: inspect(reason)

  # The conversation, and its transcript: what was said, as people see it, which
  # becomes a summary once it is long.
  defp keep(context, agent, next, instance, message, reply, pending, connection) do
    said =
      if context["resumed"],
        do: [],
        else: [%{"role" => "user", "text" => message, "at" => Agents.now()}]

    answered =
      if pending, do: [], else: [%{"role" => "assistant", "text" => reply, "at" => Agents.now()}]

    transcript = (instance["transcript"] || []) ++ said ++ answered

    changes =
      %{
        "session" => Jido.Session.encode(next.state.session),
        "messages" => (instance["messages"] || 0) + length(said),
        "transcript" => transcript
      }
      |> summarize(instance, connection)

    Agents.update_instance(context, agent, changes)
  end

  defp summarize(%{"transcript" => transcript} = changes, instance, connection)
       when length(transcript) > @window + @kept do
    {older, kept} = Enum.split(transcript, length(transcript) - @kept)

    case summary(instance["summary"], older, connection) do
      {:ok, summary} ->
        %{changes | "transcript" => kept}
        |> Map.merge(%{"summary" => summary, "recent" => kept, "session" => nil})

      {:error, _reason} ->
        changes
    end
  end

  defp summarize(changes, _instance, _connection), do: changes

  defp summary(before, messages, connection) do
    lines = Enum.map_join(messages, "\n", &"#{&1["role"]}: #{&1["text"]}")
    earlier = if before in [nil, ""], do: "", else: "What was summarized before:\n#{before}\n\n"

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.system(
          "You summarize a conversation for the agent who had it, in the language it was in. Keep names, numbers, promises, decisions and what is still open. At most 12 short lines."
        ),
        ReqLLM.Context.user(earlier <> "The conversation:\n" <> lines)
      ])

    case Bridge.generate(connection, context) do
      {:ok, response} ->
        case ReqLLM.Response.text(response) do
          text when is_binary(text) and text != "" -> {:ok, String.trim(text)}
          _none -> {:error, :empty}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait(_context, agent, %{"kind" => "approval"} = pending) do
    details =
      "#{agent["name"]} (#{agent["key"]}) wants to run #{pending["tool"]} with:\n" <>
        Jason.encode!(pending["arguments"], pretty: true)

    Bobbin.Node.wait_for_approval("#{agent["name"]}: #{pending["tool"]}?",
      details: details,
      again: true,
      data: pending
    )
  end

  defp wait(context, _agent, %{"kind" => "ask"} = pending) do
    key = Ask.reply_key()
    reply_to = %{"run_id" => context["run_id"], "key" => key}

    case Ask.ask(context, pending["agent"], pending["key"], pending["question"], reply_to) do
      {:ok, _runs} ->
        Bobbin.Node.wait_for_call(key, timeout: @ask_timeout, again: true, data: pending)

      {:error, message} ->
        {:error, message}
    end
  end
end
