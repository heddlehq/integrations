defmodule HeddleIntegrations.Services.Agents do
  @moduledoc """
  What the Agents nodes share.

  An agent is a flow that begins at the Agent trigger: its name, instructions, model
  and what it keeps (its state) are set there. Each message starts a run of it. An
  agent has an instance for each key, like one for each customer, with its own state
  and conversation, kept in Heddle's store under `"agents"` as `name/key`.

  The runs of an instance go one at a time, in the lane `agents:name/key`, so two
  messages never change it at once. What a run changes is kept only if it ends well.
  """

  alias Bobbin.Host
  alias Bobbin.Service

  @namespace "agents"
  @trigger "Agent"
  @default_key "main"
  @color "bg-sky-500/15 text-sky-700 dark:text-sky-300"
  @icon "hero-user-circle-solid"

  @doc "The type of the Agent trigger."
  def trigger, do: @trigger

  def definition(action, description, fields, outputs \\ Service.outputs()) do
    name = "#{@trigger}: #{action}"

    %{
      name: name,
      title: name,
      category: :agents,
      color: @color,
      description: description,
      icon: @icon,
      inputs: [:exec],
      outputs: outputs,
      show: true,
      ui_fields: fields
    }
  end

  def trigger_definition(fields) do
    %{
      name: @trigger,
      title: @trigger,
      category: :agents,
      color: @color,
      description:
        "Starts this flow when the agent gets a message. Its name, instructions and what it keeps are set here.",
      icon: @icon,
      inputs: [],
      outputs: [:exec],
      show: true,
      ui_fields: fields
    }
  end

  def agent_field do
    %{type: :text, name: :to, label: "Agent", default: ""}
  end

  def key_field do
    %{type: :text, name: :key, label: "Instance key", default: ""}
  end

  def message_field(default) do
    %{type: :textarea, name: :message, label: "Message", default: default}
  end

  @doc "A field of the node, with its templates filled, without the spaces around."
  def text(context, name), do: context |> Service.field(name) |> to_string() |> String.trim()

  @doc "The instance key a message names, or the agent's only one."
  def key(value) when value in [nil, ""], do: @default_key
  def key(value), do: value |> to_string() |> String.trim() |> key_or_default()

  defp key_or_default(""), do: @default_key
  defp key_or_default(key), do: key

  @doc "The agent of the run, which the Agent trigger set, or `{:error, message}`."
  def agent(%{"agent" => %{"name" => _name} = agent}), do: {:ok, agent}
  def agent(_context), do: {:error, "This node goes in an agent's flow, after the Agent trigger."}

  @doc "The instance `key` of the agent `name`, as this run sees it, or a new one."
  def instance(context, name, key) do
    case Host.store_get(context["workspace_id"], @namespace, record_key(name, key), run(context)) do
      {:ok, %{value: value}} when is_map(value) -> value
      _none -> %{}
    end
  end

  @doc """
  Changes the instance of `agent` with `changes`, kept once the run ends well.
  """
  def update_instance(context, agent, changes) do
    current = instance(context, agent["name"], agent["key"])

    value =
      current
      |> Map.merge(changes)
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

    key = record_key(agent["name"], agent["key"])

    case Host.store_put(context["workspace_id"], @namespace, key, value, run(context)) do
      {:ok, _version} -> {:ok, value}
      {:error, reason} -> {:error, "Could not keep the agent's instance: #{inspect(reason)}"}
    end
  end

  defp record_key(name, key), do: name <> "/" <> key

  defp run(%{"run_id" => run_id}) when is_binary(run_id), do: [with_run: run_id]
  defp run(_context), do: []

  @doc "The lane of an instance, so its runs go one at a time."
  def lane(name, key), do: "agents:" <> record_key(name, key)

  @doc """
  Starts a run of the agent `name` for its instance `key`, with `data`, in its lane.
  Answers `{:error, message}` when no published flow is that agent.
  """
  def deliver(context, name, key, data) do
    request = %{
      workspace_id: context["workspace_id"],
      node_type: @trigger,
      match: %{"name" => name},
      data: Map.merge(data, %{"key" => key, "from" => sender(context)}),
      lane: lane(name, key)
    }

    case Host.start_runs(request) do
      {:ok, []} -> {:error, "No published flow is the agent #{name}. Publish its flow first."}
      {:ok, runs} -> {:ok, runs}
      {:error, message} -> {:error, message}
    end
  end

  # Who sends a message: an agent, from its flow, or another flow.
  defp sender(%{"agent" => %{"name" => name, "key" => key}}),
    do: %{"type" => "agent", "agent" => name, "key" => key}

  defp sender(context),
    do: %{"type" => "flow", "flow_id" => context["flow_id"], "run_id" => context["run_id"]}

  @doc """
  The state an agent keeps, from the JSON of its trigger: each field with its
  starting value, whose type it keeps.
  """
  def declared_state(value) when value in [nil, ""], do: {:ok, %{}}
  def declared_state(value) when is_map(value), do: {:ok, value}

  def declared_state(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _other -> {:error, "State must be a JSON object, like {\"stage\": \"new\"}."}
    end
  end

  def declared_state(_value), do: {:error, "State must be a JSON object."}

  @doc """
  The state of an instance, for what its agent keeps now: a field kept before stays
  when its type is the same, and new fields start at their values. An instance made
  with an older version of the flow moves to the new one this way.
  """
  def migrate(declared, stored) when is_map(stored) do
    Map.new(declared, fn {field, start} ->
      case Map.fetch(stored, field) do
        {:ok, value} -> {field, if(same_type?(start, value), do: value, else: start)}
        :error -> {field, start}
      end
    end)
  end

  def migrate(declared, _stored), do: declared

  @doc """
  Applies `changes` to `state`. Each field must be one the agent keeps, with its type.
  """
  def change_state(state, declared, changes) do
    Enum.reduce_while(changes, {:ok, state}, fn {field, value}, {:ok, acc} ->
      case Map.fetch(declared, field) do
        :error ->
          {:halt, {:error, "#{field} isn't in the agent's state. Add it to its Agent trigger."}}

        {:ok, start} ->
          if same_type?(start, value),
            do: {:cont, {:ok, Map.put(acc, field, value)}},
            else: {:halt, {:error, "#{field} must be #{type(start)}."}}
      end
    end)
  end

  defp same_type?(nil, _value), do: true
  defp same_type?(_start, nil), do: true
  defp same_type?(start, value), do: type(start) == type(value)

  defp type(value) when is_binary(value), do: "text"
  defp type(value) when is_number(value), do: "a number"
  defp type(value) when is_boolean(value), do: "true or false"
  defp type(value) when is_list(value), do: "a list"
  defp type(value) when is_map(value), do: "an object"
end
