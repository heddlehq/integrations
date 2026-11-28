defmodule HeddleIntegrations.Services.Agents do
  @moduledoc """
  What the Agents nodes share.

  An agent is a flow that begins at the Agent trigger: its name, instructions, model
  and what it keeps (its state) are set there. Each message starts a run of it. An
  agent has an instance for each key, like one for each customer, with its own state
  and conversation, kept in Heddle's store under `"agents"` as `name/key`.

  The runs of an instance go one at a time, in the lane `agents:name/key`, so two
  messages never change it at once. What a run changes is kept only if it ends well.

  Besides the instances, the store keeps, outside any run:

    * `agents_control`: which agents, or instances, are paused (`name` or `name/key`).
    * `agents_budget`: the messages of this hour and the cost of today, by instance.
    * `agents_chats`: the conversation of each chat (`name/key`), as people see it.

  A chain of agents messaging each other stops `@max_depth` messages deep.
  """

  alias Bobbin.Host
  alias Bobbin.Service

  @namespace "agents"
  @control "agents_control"
  @budget "agents_budget"
  @chats "agents_chats"
  @trigger "Agent"
  @event_trigger "Agent Event"
  @default_key "main"
  @max_depth 5
  @chat_kept 200
  @color "bg-sky-500/15 text-sky-700 dark:text-sky-300"
  @icon "logo-agents"

  @doc "The type of the Agent trigger."
  def trigger, do: @trigger

  @doc "The type of the trigger of events, in any flow."
  def event_trigger, do: @event_trigger

  @doc "How deep a chain of agents messaging each other goes."
  def max_depth, do: @max_depth

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

  def trigger_definition(name, description, fields) do
    %{
      name: name,
      title: name,
      category: :agents,
      color: @color,
      description: description,
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

  @doc "A list of names a field holds, separated by commas or lines."
  def names(context, name) do
    context
    |> text(name)
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "A whole number a field holds, or nil when it is blank or not one."
  def number(context, name) do
    case Float.parse(text(context, name)) do
      {value, ""} when value >= 0 -> value
      _blank -> nil
    end
  end

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

  @doc "Whether the instance `key` of `name` was ever kept."
  def instance?(context, name, key) do
    match?(
      {:ok, _record},
      Host.store_get(context["workspace_id"], @namespace, record_key(name, key), run(context))
    )
  end

  @doc """
  Changes the instance of `agent` with `changes`, kept once the run ends well.
  """
  def update_instance(context, agent, changes) do
    current = instance(context, agent["name"], agent["key"])

    value =
      current
      |> Map.merge(changes)
      |> Map.put("updated_at", now())

    key = record_key(agent["name"], agent["key"])

    case Host.store_put(context["workspace_id"], @namespace, key, value, run(context)) do
      {:ok, _version} -> {:ok, value}
      {:error, reason} -> {:error, "Could not keep the agent's instance: #{inspect(reason)}"}
    end
  end

  @doc """
  Forgets the instance `key` of `name`: its state, conversation and schedules, which
  are cancelled. Kept once the run ends well. Answers what it was.
  """
  def forget_instance(context, name, key) do
    workspace_id = context["workspace_id"]
    current = instance(context, name, key)

    for schedule <- current["schedules"] || [],
        run_id <- schedule["runs"] || [],
        do: Host.cancel_run(workspace_id, run_id)

    _deleted = Host.store_delete(workspace_id, @namespace, record_key(name, key), run(context))
    _budget = Host.store_delete(workspace_id, @budget, record_key(name, key), [])
    _chat = Host.store_delete(workspace_id, @chats, record_key(name, key), [])
    {:ok, current}
  end

  @doc "The instances of `name` whose keys begin with `prefix`, by key."
  def instances(context, name, prefix \\ "", limit \\ 100) do
    {:ok, records} =
      Host.store_list(
        context["workspace_id"],
        @namespace,
        record_key(name, prefix),
        run(context) ++ [limit: limit]
      )

    Enum.map(records, fn %{key: record, value: value} ->
      Map.put(value, "key", String.replace_prefix(record, name <> "/", ""))
    end)
  end

  defp record_key(name, key), do: name <> "/" <> key

  defp run(%{"run_id" => run_id}) when is_binary(run_id), do: [with_run: run_id]
  defp run(_context), do: []

  @doc "The lane of an instance, so its runs go one at a time."
  def lane(name, key), do: "agents:" <> record_key(name, key)

  @doc """
  Starts a run of the agent `name` for its instance `key`, with `data`, in its lane.
  Answers `{:error, message}` when no published flow is that agent, it is paused, or
  the chain of messages that led here is too deep.

  `at:` starts it then, as a schedule, which begins a chain of its own. `from:` says
  who sends it, when it isn't the run asking, like a person on a chat.
  """
  def deliver(context, name, key, data, opts \\ []) do
    depth = if opts[:at], do: 0, else: depth(context) + 1

    cond do
      depth > @max_depth ->
        {:error,
         "Agents messaged each other #{@max_depth} times in a row, so this message to #{name} " <>
           "stops here. A schedule starts over."}

      paused?(context["workspace_id"], name, key) and not Keyword.get(opts, :paused_ok, false) ->
        {:error, "The agent #{name} is paused. Resume it to send it messages."}

      true ->
        request =
          %{
            workspace_id: context["workspace_id"],
            node_type: @trigger,
            match: %{"name" => name},
            data:
              Map.merge(data, %{
                "key" => key,
                "from" => opts[:from] || sender(context),
                "depth" => depth
              }),
            lane: lane(name, key)
          }
          |> then(&if(opts[:at], do: Map.put(&1, :at, opts[:at]), else: &1))

        case Host.start_runs(request) do
          {:ok, []} -> {:error, "No published flow is the agent #{name}. Publish its flow first."}
          {:ok, runs} -> {:ok, runs}
          {:error, message} -> {:error, message}
        end
    end
  end

  @doc "How many messages led to this run, from agent to agent."
  def depth(%{"agent" => %{"depth" => depth}}) when is_integer(depth), do: depth
  def depth(%{"agent_depth" => depth}) when is_integer(depth), do: depth
  def depth(_context), do: 0

  # Who sends a message: an agent, from its flow, or another flow.
  defp sender(%{"agent" => %{"name" => name, "key" => key}}),
    do: %{"type" => "agent", "agent" => name, "key" => key}

  defp sender(context),
    do: %{"type" => "flow", "flow_id" => context["flow_id"], "run_id" => context["run_id"]}

  @doc """
  Whether `from` may message the agent, by the names its trigger allows: agent names,
  `chat` for people, `flows` for any flow, `flow:ID` for one. Nothing listed lets
  anyone. Its own schedules always may.
  """
  def allowed?(_from, []), do: true
  def allowed?(%{"type" => "schedule"}, _allowed), do: true

  def allowed?(from, allowed) do
    allowed = Enum.map(allowed, &String.downcase/1)

    case from do
      %{"type" => "agent", "agent" => name} -> String.downcase(name) in allowed
      %{"type" => "chat"} -> "chat" in allowed
      %{"type" => "flow", "flow_id" => id} -> "flows" in allowed or "flow:#{id}" in allowed
      _other -> "flows" in allowed
    end
  end

  @doc "Who sent a message, in words, to say why it was refused."
  def describe_sender(%{"type" => "agent", "agent" => name}), do: "the agent #{name}"
  def describe_sender(%{"type" => "chat"}), do: "a chat"

  def describe_sender(%{"type" => "flow", "flow_id" => id}) when not is_nil(id),
    do: "the flow #{id}"

  def describe_sender(_from), do: "a flow"

  ## Pausing

  @doc "Whether the agent `name`, or its instance `key`, is paused."
  def paused?(workspace_id, name, key) do
    control(workspace_id, name)["paused"] == true or
      (key != nil and control(workspace_id, record_key(name, key))["paused"] == true)
  end

  @doc "Pauses or resumes the agent `name`, or only its instance `key`."
  def set_paused(workspace_id, name, key, paused?) do
    record = if key in [nil, ""], do: name, else: record_key(name, key)

    result =
      if paused?,
        do:
          Host.store_put(workspace_id, @control, record, %{"paused" => true, "at" => now()}, []),
        else: Host.store_delete(workspace_id, @control, record, [])

    case result do
      {:ok, _version} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, "Could not change the agent: #{inspect(reason)}"}
    end
  end

  @doc "The instances of `name` paused one by one, and whether the whole agent is."
  def pauses(workspace_id, name) do
    {:ok, records} = Host.store_list(workspace_id, @control, name, limit: 500)

    Enum.reduce(records, %{agent: false, keys: []}, fn %{key: record}, acc ->
      cond do
        record == name ->
          %{acc | agent: true}

        String.starts_with?(record, name <> "/") ->
          %{acc | keys: acc.keys ++ [String.replace_prefix(record, name <> "/", "")]}

        true ->
          acc
      end
    end)
  end

  defp control(workspace_id, record) do
    case Host.store_get(workspace_id, @control, record, []) do
      {:ok, %{value: value}} when is_map(value) -> value
      _none -> %{}
    end
  end

  ## Budget

  @doc """
  Counts a message to the instance `key` of `name`, and says whether it is within
  `max_hour` messages this hour and `max_cost` (in US dollars) spent today. A blank
  limit has none. Counted outside the run, so a run that fails still counts.
  """
  def spend_message(workspace_id, name, key, max_hour, max_cost) do
    budget = budget(workspace_id, name, key)
    messages = budget["messages"] + 1

    cond do
      max_hour && messages > max_hour ->
        {:error,
         "#{name} got #{trunc(max_hour)} messages for #{key} this hour, its limit. " <>
           "Messages after that wait for the next hour."}

      max_cost && budget["cost"] >= max_cost ->
        {:error, "#{name} spent its $#{max_cost} for #{key} today. It answers again tomorrow."}

      true ->
        put_budget(workspace_id, name, key, %{budget | "messages" => messages})
    end
  end

  @doc "Adds `cost` (US dollars) to what the instance spent today."
  def spend_cost(_workspace_id, _name, _key, cost) when cost in [nil, 0, +0.0], do: :ok

  def spend_cost(workspace_id, name, key, cost) do
    budget = budget(workspace_id, name, key)
    put_budget(workspace_id, name, key, %{budget | "cost" => budget["cost"] + cost})
  end

  @doc "The messages of this hour and the cost of today, of an instance."
  def budget(workspace_id, name, key) do
    now = DateTime.utc_now()
    hour = Calendar.strftime(now, "%Y-%m-%dT%H")
    day = Date.to_iso8601(DateTime.to_date(now))

    stored =
      case Host.store_get(workspace_id, @budget, record_key(name, key), []) do
        {:ok, %{value: value}} when is_map(value) -> value
        _none -> %{}
      end

    %{
      "hour" => hour,
      "day" => day,
      "messages" => if(stored["hour"] == hour, do: stored["messages"] || 0, else: 0),
      "cost" => if(stored["day"] == day, do: stored["cost"] || 0, else: 0)
    }
  end

  defp put_budget(workspace_id, name, key, budget) do
    case Host.store_put(workspace_id, @budget, record_key(name, key), budget, []) do
      {:ok, _version} -> :ok
      {:error, reason} -> {:error, "Could not count the agent's budget: #{inspect(reason)}"}
    end
  end

  ## Chats

  @doc "Adds a message to the chat of the instance `key` of `name`, as people see it."
  def chat_append(workspace_id, name, key, role, text) do
    messages = chat_messages(workspace_id, name, key)
    message = %{"role" => to_string(role), "text" => text, "at" => now()}
    kept = Enum.take(messages ++ [message], -@chat_kept)

    case Host.store_put(workspace_id, @chats, record_key(name, key), %{"messages" => kept}, []) do
      {:ok, _version} -> :ok
      {:error, reason} -> {:error, "Could not keep the chat: #{inspect(reason)}"}
    end
  end

  @doc "Takes back the last message of a chat, which could not be sent."
  def chat_drop_last(workspace_id, name, key) do
    messages = chat_messages(workspace_id, name, key) |> Enum.drop(-1)

    _put =
      Host.store_put(workspace_id, @chats, record_key(name, key), %{"messages" => messages}, [])

    :ok
  end

  @doc "The messages of the chat of an instance, oldest first."
  def chat_messages(workspace_id, name, key) do
    case Host.store_get(workspace_id, @chats, record_key(name, key), []) do
      {:ok, %{value: %{"messages" => messages}}} when is_list(messages) -> messages
      _none -> []
    end
  end

  ## Events

  @doc """
  Starts the flows that wait for `event` with the When an Agent Publishes trigger,
  and those that wait for any event. Answers the runs started.
  """
  def publish_event(context, event, data) do
    source =
      case context do
        %{"agent" => %{"name" => name, "key" => key}} -> %{"agent" => name, "key" => key}
        _flow -> %{"flow_id" => context["flow_id"]}
      end

    payload =
      Map.merge(source, %{
        "event" => event,
        "data" => data,
        "depth" => depth(context) + 1,
        "at" => now()
      })

    if payload["depth"] > @max_depth do
      {:error,
       "Agents and events led to each other #{@max_depth} times in a row, so #{event} stops here."}
    else
      matches =
        if event == "", do: [%{"event" => ""}], else: [%{"event" => event}, %{"event" => ""}]

      Enum.reduce_while(matches, {:ok, []}, fn match, {:ok, runs} ->
        request = %{
          workspace_id: context["workspace_id"],
          node_type: @event_trigger,
          match: match,
          data: payload
        }

        case Host.start_runs(request) do
          {:ok, started} -> {:cont, {:ok, runs ++ started}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
    end
  end

  ## State

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

  @doc "The state of the agent of this run as it is now, with what this run changed."
  def current_state(context, agent) do
    migrate(agent["declared"] || %{}, instance(context, agent["name"], agent["key"])["state"])
  end

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

  @doc """
  Reads `text` as a value of the type of `start`, for a model that writes every value
  as text: `"3"` for a number, `"true"` for true or false, JSON for a list or object.
  """
  def coerce(start, text) when is_binary(text) and is_number(start) do
    case Float.parse(String.trim(text)) do
      {number, ""} -> if number == trunc(number), do: trunc(number), else: number
      _other -> text
    end
  end

  def coerce(start, text) when is_binary(text) and is_boolean(start) do
    case String.downcase(String.trim(text)) do
      value when value in ~w(true yes sim 1) -> true
      value when value in ~w(false no não nao 0) -> false
      _other -> text
    end
  end

  def coerce(start, text) when is_binary(text) and (is_list(start) or is_map(start)) do
    case Jason.decode(text) do
      {:ok, value} -> value
      _other -> text
    end
  end

  def coerce(_start, value), do: value

  defp same_type?(nil, _value), do: true
  defp same_type?(_start, nil), do: true
  defp same_type?(start, value), do: type(start) == type(value)

  defp type(value) when is_binary(value), do: "text"
  defp type(value) when is_number(value), do: "a number"
  defp type(value) when is_boolean(value), do: "true or false"
  defp type(value) when is_list(value), do: "a list"
  defp type(value) when is_map(value), do: "an object"

  @doc "Now, as ISO 8601, as the store keeps dates."
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
