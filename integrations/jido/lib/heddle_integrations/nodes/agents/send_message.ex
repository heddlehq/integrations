defmodule HeddleIntegrations.Nodes.Agents.SendMessage do
  @moduledoc """
  Sends a message to an agent and goes on without waiting: a run of the agent's flow
  starts for the instance `key`. Messages to one instance are handled one at a time,
  in the order they were sent. To wait for its reply, use Agent: Ask.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "Send Message",
      "Sends a message to an agent, without waiting for its reply.",
      [Agents.agent_field(), Agents.key_field(), Agents.message_field("{{result}}")]
    )
  end

  @impl true
  def handler(context, _input) do
    name = Agents.text(context, "to")
    key = Agents.key(Agents.text(context, "key"))

    with :ok <- check(name),
         {:ok, runs} <- Agents.deliver(context, name, key, %{"message" => message(context)}) do
      Service.success(context, %{"agent" => name, "key" => key, "runs" => runs})
    else
      {:error, message} -> Service.failure(context, message)
    end
  end

  defp check(""), do: {:error, "Name the agent to send the message to."}
  defp check(_name), do: :ok

  # A message that is a single placeholder, like {{result}}, goes as the value itself.
  @doc false
  def message(context) do
    template = String.trim(context["message"] || "")

    case Regex.run(~r/\A\{\{([^{}]+)\}\}\z/, template) do
      [_match, path] ->
        case Bobbin.Template.fetch(context, path) do
          value when is_binary(value) or is_nil(value) -> Agents.text(context, "message")
          value -> Jason.encode!(value)
        end

      nil ->
        Agents.text(context, "message")
    end
  end
end
