defmodule HeddleIntegrations.Nodes.Agents.Agent do
  @moduledoc """
  The start of an agent's flow. Each message to the agent starts a run here, with
  `agent` in the context: its `name`, the instance `key`, the `message`, who it is
  `from`, and its `state`, as this version of the flow keeps it.

  Its fields also limit it: how many messages an instance takes an hour, what it may
  spend a day, and who may message it. A message past them fails its run, saying why.

  People talk to it on its chat page (`chat_message/4`), each conversation an
  instance, and its drawer shows its instances (`panel/2`).
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
         :ok <- check_message(context, data),
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

  # A run started by hand, from the editor, brings no message.
  defp check_message(context, data) do
    if context["trigger"] in ["manual", "test"] and message(data["message"]) == "",
      do:
        {:error,
         "An agent runs when it gets a message. To try it, publish the flow and press Chat in this node's drawer, or send it one with Agent: Send Message."},
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

  ## The chat page

  @impl true
  def chat_message(workspace_id, controls, conversation, text) do
    name = controls |> Map.get("name", "") |> to_string() |> String.trim()
    key = Agents.key(conversation)

    with :ok <- if(name == "", do: {:error, "This agent has no name yet."}, else: :ok),
         :ok <- Agents.chat_append(workspace_id, name, key, :visitor, text) do
      case Agents.deliver(%{"workspace_id" => workspace_id}, name, key, %{"message" => text},
             from: %{"type" => "chat", "conversation" => key}
           ) do
        {:ok, runs} ->
          {:ok, runs}

        {:error, message} ->
          Agents.chat_drop_last(workspace_id, name, key)
          {:error, message}
      end
    end
  end

  @impl true
  def chat_history(workspace_id, controls, conversation) do
    name = controls |> Map.get("name", "") |> to_string() |> String.trim()

    for message <- Agents.chat_messages(workspace_id, name, Agents.key(conversation)) do
      %{
        role: if(message["role"] == "visitor", do: :visitor, else: :agent),
        text: message["text"],
        at: message["at"]
      }
    end
  end

  ## The drawer

  @impl true
  def panel(workspace_id, controls) do
    name = controls |> Map.get("name", "") |> to_string() |> String.trim()

    if name == "" do
      [%{title: "Instances", text: "Give the agent a name to see its instances."}]
    else
      context = %{"workspace_id" => workspace_id}
      instances = Agents.instances(context, name, "", 50)
      pauses = Agents.pauses(workspace_id, name)

      [
        status(name, pauses),
        instances_section(workspace_id, name, instances),
        schedules_section(instances)
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  defp status(name, %{agent: true}),
    do: %{title: "Paused", text: "#{name} is paused: it takes no messages until it is resumed."}

  defp status(name, %{keys: [_ | _] = keys}),
    do: %{
      title: "Paused",
      text: "These instances of #{name} are paused: #{Enum.join(keys, ", ")}."
    }

  defp status(_name, _pauses), do: nil

  defp instances_section(workspace_id, name, instances) do
    rows =
      instances
      |> Enum.sort_by(&(&1["updated_at"] || ""), :desc)
      |> Enum.map(fn instance ->
        budget = Agents.budget(workspace_id, name, instance["key"])

        %{
          "Key" => instance["key"],
          "State" => instance["state"] || %{},
          "Messages" => instance["messages"] || 0,
          "Today" => "$" <> :erlang.float_to_binary(budget["cost"] / 1, decimals: 4),
          "Last message" => instance["updated_at"]
        }
      end)

    %{
      title: "Instances",
      columns: ["Key", "State", "Messages", "Today", "Last message"],
      rows: rows,
      empty: "No instance yet. Each key that gets a message becomes one."
    }
  end

  defp schedules_section(instances) do
    rows =
      for instance <- instances, schedule <- instance["schedules"] || [] do
        %{
          "Key" => instance["key"],
          "At" => schedule["at"],
          "Message" => schedule["message"],
          "Id" => schedule["id"]
        }
      end

    if rows == [],
      do: nil,
      else: %{
        title: "Scheduled",
        columns: ["Key", "At", "Message", "Id"],
        rows: Enum.sort_by(rows, & &1["At"])
      }
  end
end
