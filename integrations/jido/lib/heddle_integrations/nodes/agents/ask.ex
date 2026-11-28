defmodule HeddleIntegrations.Nodes.Agents.Ask do
  @moduledoc """
  Sends a message to an agent and waits for its reply, which its flow gives with
  Agent: Reply. The run pauses, holding no worker, and goes on through `success` with
  `result.reply`, or through `timeout` when the agent doesn't answer in time.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Nodes.Agents.SendMessage
  alias HeddleIntegrations.Services.Agents

  @default_timeout 300

  definition do
    Agents.definition(
      "Ask",
      "Sends a message to an agent and waits for its reply.",
      [
        Agents.agent_field(),
        Agents.key_field(),
        Agents.message_field("{{result}}"),
        %{type: :number, name: :timeout, label: "Wait up to (seconds)", default: "300"}
      ],
      ["success", "timeout", "error"]
    )
  end

  @impl true
  def handler(context, _input) do
    name = Agents.text(context, "to")
    key = Agents.key(Agents.text(context, "key"))
    reply_to = %{"run_id" => context["run_id"], "key" => reply_key()}

    with :ok <- check(context, name, key),
         {:ok, _runs} <- ask(context, name, key, SendMessage.message(context), reply_to) do
      Bobbin.Node.wait_for_call(reply_to["key"], timeout: timeout(context))
    else
      {:error, message} -> Service.failure(context, message)
    end
  end

  @doc """
  Sends `message` to the instance `key` of `name`, to reply to `reply_to`. An agent
  waiting for an answer can't be asked back by who it waits for: its runs wait in its
  lane, so neither would answer.
  """
  def ask(context, name, key, message, reply_to) do
    waiting =
      case context["agent"] do
        %{"name" => own, "key" => own_key} = agent ->
          List.wrap(agent["waiting"]) ++ ["#{own}/#{own_key}"]

        _flow ->
          []
      end

    if "#{name}/#{key}" in waiting do
      {:error,
       "#{name} is waiting for an answer from this agent, so it can't be asked now. Use Agent: Send Message."}
    else
      Agents.deliver(context, name, key, %{
        "message" => message,
        "reply_to" => reply_to,
        "waiting" => waiting
      })
    end
  end

  @doc "A key no other question has, to wait for its answer."
  def reply_key, do: "agents:" <> unique()

  defp check(_context, "", _key), do: {:error, "Name the agent to ask."}

  defp check(context, name, key) do
    cond do
      not is_binary(context["run_id"]) ->
        {:error, "Agent: Ask waits for a reply, so it runs only in a run of a flow."}

      # Its own instance can't answer while this run, in its lane, waits for it.
      match?(%{"name" => ^name, "key" => ^key}, context["agent"]) ->
        {:error, "An agent can't ask itself. Use Agent: Think."}

      true ->
        :ok
    end
  end

  defp timeout(context) do
    case Integer.parse(Agents.text(context, "timeout")) do
      {seconds, ""} when seconds > 0 -> seconds
      _other -> @default_timeout
    end
  end

  defp unique, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
