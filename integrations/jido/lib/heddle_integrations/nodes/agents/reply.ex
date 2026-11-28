defmodule HeddleIntegrations.Nodes.Agents.Reply do
  @moduledoc """
  Answers who sent the message. When an Agent: Ask node waits for the agent, its run
  goes on with the reply. A message sent
  with Agent: Send Message waits for no reply, and `result.answered` is false.
  """

  use Bobbin.Node

  alias Bobbin.Host
  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "Reply",
      "Answers who sent the message, like an Agent: Ask node waiting for the agent.",
      [Agents.message_field("{{result.reply}}")]
    )
  end

  @impl true
  def handler(context, _input) do
    with {:ok, agent} <- Agents.agent(context),
         reply = Agents.text(context, "message"),
         {:ok, answered} <- answer(context, agent, reply) do
      Service.success(context, %{"reply" => reply, "answered" => answered})
    else
      {:error, message} -> Service.failure(context, message)
    end
  end

  defp answer(context, agent, reply), do: answer_asking(context, agent, reply)

  defp answer_asking(context, agent, reply) do
    case agent["reply_to"] do
      %{"run_id" => run_id, "key" => key} ->
        value = %{"reply" => reply, "agent" => agent["name"], "key" => agent["key"]}

        case Host.resume_run(context["workspace_id"], run_id, key, value) do
          :ok -> {:ok, true}
          # The one asking stopped waiting, so nobody gets it.
          {:error, :not_waiting} -> {:ok, false}
          {:error, :not_found} -> {:ok, false}
          {:error, message} -> {:error, message}
        end

      _nobody ->
        {:ok, false}
    end
  end
end
