defmodule HeddleIntegrations.Nodes.Agents.Think do
  @moduledoc """
  The agent works on the message with its model, using the nodes connected to `tools`,
  and answers. It remembers the conversation of its instance: the last messages go
  with each new one. `result.reply` is what it said.

  The reasoning is Jido's ReAct, see `HeddleIntegrations.Agents.Brain`.
  """

  use Bobbin.Node

  alias Bobbin.Host
  alias Bobbin.Service
  alias HeddleIntegrations.Agents.Brain
  alias HeddleIntegrations.Agents.Bridge
  alias HeddleIntegrations.Services.Agents

  # The messages of the conversation that go with a new one.
  @window 20

  definition do
    Agents.definition(
      "Think",
      "The agent answers the message with its model, and can use the nodes connected to tools.",
      [Agents.message_field("{{agent.message}}")],
      ["success", "error", "tools"]
    )
  end

  @impl true
  def handler(context, _input) do
    case Agents.agent(context) do
      {:ok, agent} -> {:with_tools, fn tools, call -> think(context, agent, tools, call) end}
      {:error, message} -> Service.failure(context, message)
    end
  end

  defp think(context, agent, tools, call) do
    message = Agents.text(context, "message")

    ai =
      %{"workspace_id" => context["workspace_id"]}
      |> Map.merge(Map.take(agent, ~w(credential model)))

    with :ok <- check_message(message),
         {:ok, connection} <- Host.ai_connection(ai, :text),
         instance = Agents.instance(context, agent["name"], agent["key"]),
         {:ok, brain} <- brain(agent, instance),
         {:ok, signal} <- request(agent, message, connection),
         {:ok, next, reply} <- reason(brain, signal, tools, connection, call),
         {:ok, _instance} <- keep(context, agent, next, instance) do
      {:ok, %{"reply" => reply}}
    end
  end

  defp check_message(""), do: {:error, "The message is empty."}
  defp check_message(_message), do: :ok

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

  defp request(agent, message, connection) do
    Brain.request_signal(%{
      input: message,
      instructions: instructions(agent),
      model: model_name(connection.model),
      context: %{max_messages: @window}
    })
  end

  defp instructions(agent) do
    who = "You are the agent #{agent["name"]}. This conversation is with #{agent["key"]}."

    state =
      if agent["state"] == %{},
        do: "",
        else: "\n\nWhat you know (your state), as JSON: #{Jason.encode!(agent["state"])}"

    [agent["instructions"], who <> state]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # Jido wants a model name as text, for what it knows about it. The call itself goes
  # with the connection Heddle gave, see Bridge.
  defp model_name({provider, name, _options}) when is_binary(name), do: "#{provider}:#{name}"
  defp model_name(%{provider: provider, id: id}), do: "#{provider}:#{id}"
  defp model_name(name) when is_binary(name), do: name
  defp model_name(_other), do: "openai:gpt-4o-mini"

  defp reason(brain, signal, tools, connection, call) do
    jido = %{
      jido_ai_inference_client: Brain.Model,
      jido_ai_tool_sources: [{Brain.Tools, %{tools: tools}}]
    }

    fun = fn -> Brain.cmd(brain, signal, context: jido) end

    case Bridge.run(fun, connection, call) do
      {:ok, next, directives} -> reply(next, directives)
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "The agent could not answer: #{inspect(reason)}"}
      other -> {:error, "The agent could not answer: #{inspect(other)}"}
    end
  end

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

  defp keep(context, agent, next, instance) do
    Agents.update_instance(context, agent, %{
      "session" => Jido.Session.encode(next.state.session),
      "messages" => (instance["messages"] || 0) + 1
    })
  end
end
