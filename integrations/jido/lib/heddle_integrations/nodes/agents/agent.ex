defmodule HeddleIntegrations.Nodes.Agents.Agent do
  @moduledoc """
  The start of an agent's flow. Each message to the agent starts a run here, with
  `agent` in the context: its `name`, the instance `key`, the `message`, who it is
  `from`, and its `state`, as this version of the flow keeps it.

  Its fields also limit it: how many messages an instance takes an hour, what it may
  spend a day, and who may message it. A message past them fails its run, saying why.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.trigger_definition(
      Agents.trigger(),
      "Starts this flow when the agent gets a message. Its name, instructions, what it keeps and its limits are set here.",
      [
        %{type: :text, name: :name, label: "Name", default: ""},
        %{type: :textarea, name: :instructions, label: "Instructions", default: ""},
        Service.credential_field("ai"),
        %{type: :model, name: :model, label: "Model", capability: :text, default: ""},
        %{type: :json, name: :state, label: "State", default: "{}"},
        %{
          type: :text,
          name: :max_messages,
          label: "Messages per hour, per instance",
          default: ""
        },
        %{
          type: :text,
          name: :max_cost,
          label: "Spending per day, per instance (US$)",
          default: ""
        },
        %{type: :text, name: :allowed, label: "Who may message it", default: ""}
      ]
    )
  end

  @impl true
  def handler(context, _input) do
    data = if is_map(context["result"]), do: context["result"], else: %{}
    name = Agents.text(context, "name")
    key = Agents.key(data["key"])
    from = data["from"] || %{"type" => "flow"}

    with :ok <- check_name(name),
         {:ok, declared} <- Agents.declared_state(context["state"]),
         :ok <- check_sender(context, name, from),
         :ok <- check_paused(context, name, key),
         :ok <- check_budget(context, name, key) do
      instance = Agents.instance(context, name, key)

      agent = %{
        "name" => name,
        "key" => key,
        "message" => message(data["message"]),
        "from" => from,
        "state" => Agents.migrate(declared, instance["state"]),
        "declared" => declared,
        "instructions" => Agents.text(context, "instructions"),
        "credential" => context["credential"],
        "model" => context["model"],
        "reply_to" => data["reply_to"],
        "depth" => depth(data["depth"]),
        "waiting" => List.wrap(data["waiting"]),
        "messages" => instance["messages"] || 0
      }

      with :ok <- forget_schedule(context, agent, instance, data["schedule"]) do
        result = Map.take(agent, ["name", "key", "message", "from", "state"])
        {:ok, context |> Map.put("agent", agent) |> Map.put("result", result), "exec"}
      end
    end
  end

  defp check_name(""), do: {:error, "Give the agent a name."}

  defp check_name(name) do
    if String.contains?(name, "/"),
      do: {:error, "An agent's name can't have a /."},
      else: :ok
  end

  defp check_sender(context, name, from) do
    if Agents.allowed?(from, Agents.names(context, "allowed")),
      do: :ok,
      else:
        {:error,
         "#{name} doesn't take messages from #{Agents.describe_sender(from)}. See Who may message it."}
  end

  defp check_paused(context, name, key) do
    if Agents.paused?(context["workspace_id"], name, key),
      do: {:error, "The agent #{name} is paused, so this message was not handled."},
      else: :ok
  end

  defp check_budget(context, name, key) do
    Agents.spend_message(
      context["workspace_id"],
      name,
      key,
      Agents.number(context, "max_messages"),
      Agents.number(context, "max_cost")
    )
  end

  # A schedule that came is no longer waiting.
  defp forget_schedule(_context, _agent, _instance, nil), do: :ok

  defp forget_schedule(context, agent, instance, id) do
    schedules = Enum.reject(instance["schedules"] || [], &(&1["id"] == id))

    case Agents.update_instance(context, agent, %{"schedules" => schedules}) do
      {:ok, _instance} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp depth(depth) when is_integer(depth), do: depth
  defp depth(_depth), do: 0

  defp message(nil), do: ""
  defp message(text) when is_binary(text), do: text
  defp message(value), do: Jason.encode!(value)
end
