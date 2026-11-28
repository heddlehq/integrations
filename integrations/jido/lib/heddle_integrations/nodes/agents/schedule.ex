defmodule HeddleIntegrations.Nodes.Agents.Schedule do
  @moduledoc """
  Sends the agent a message later, like a follow-up three days from now. A run of
  its flow starts then, for this instance or another key, from `schedule`. Until it
  comes, it shows in the trigger's drawer, and Agent: Cancel Schedule calls it off.
  `result.id` names it.

  Call off the ones set before moves a follow-up each time someone writes, and Not
  from a scheduled message keeps a follow-up from scheduling another, forever.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  @units %{"minutes" => 60, "hours" => 3_600, "days" => 86_400}
  @longest 366 * 86_400

  definition do
    Agents.definition(
      "Schedule",
      "Sends the agent a message later, like a follow-up in three days.",
      [
        Agents.message_field(""),
        %{type: :text, name: :in, label: "In", default: "1"},
        %{
          type: :select,
          name: :unit,
          label: "Unit",
          options: ["minutes", "hours", "days"],
          default: "days"
        },
        %{type: :text, name: :at, label: "Or at (ISO 8601, overrides In)", default: ""},
        Agents.key_field(),
        %{type: :boolean, name: :replace, label: "Call off the ones set before", default: false},
        %{
          type: :boolean,
          name: :not_scheduled,
          label: "Not from a scheduled message",
          default: false
        }
      ]
    )
  end

  @impl true
  def handler(context, _input) do
    case Agents.agent(context) do
      {:ok, %{"from" => %{"type" => "schedule"}}} = found ->
        if on?(context["not_scheduled"]),
          do: Service.success(context, %{"skipped" => true}),
          else: schedule(context, found)

      found ->
        schedule(context, found)
    end
  end

  defp on?(value), do: value in [true, "true", "on", "1"]

  defp schedule(context, found) do
    with {:ok, agent} <- found,
         {:ok, at} <- at(context),
         message = Agents.text(context, "message"),
         :ok <- if(message == "", do: {:error, "Write the message to send later."}, else: :ok),
         key = key(context, agent),
         :ok <- replace(context, agent, key),
         id = new_id(),
         {:ok, runs} <- schedule(context, agent, key, message, at, id) do
      entry = %{
        "id" => id,
        "runs" => Enum.map(runs, & &1["run_id"]),
        "at" => DateTime.to_iso8601(at),
        "message" => message
      }

      with {:ok, _instance} <- keep(context, agent, key, entry) do
        Service.success(context, entry |> Map.delete("runs") |> Map.put("key", key))
      end
    end
    |> case do
      {:ok, _context, _output} = done -> done
      {:error, message} -> Service.failure(context, message)
    end
  end

  defp key(context, agent) do
    case Agents.text(context, "key") do
      "" -> agent["key"]
      key -> Agents.key(key)
    end
  end

  # Calls off what was set before for the instance, so a new message moves a follow-up.
  defp replace(context, agent, key) do
    if on?(context["replace"]) do
      current = Agents.instance(context, agent["name"], key)

      for schedule <- current["schedules"] || [],
          run_id <- schedule["runs"] || [],
          do: Bobbin.Host.cancel_run(context["workspace_id"], run_id)

      case Agents.update_instance(context, %{agent | "key" => key}, %{"schedules" => []}) do
        {:ok, _instance} -> :ok
        {:error, message} -> {:error, message}
      end
    else
      :ok
    end
  end

  defp new_id, do: "s-" <> (9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  defp schedule(context, agent, key, message, at, id) do
    Agents.deliver(context, agent["name"], key, %{"message" => message, "schedule" => id},
      at: at,
      from: %{"type" => "schedule"},
      paused_ok: true
    )
    |> case do
      {:ok, runs} -> {:ok, runs}
      {:error, message} -> {:error, message}
    end
  end

  # The instance keeps its schedules, to show them and call them off. Another key's is
  # kept in that instance.
  defp keep(context, agent, key, entry) do
    target = %{agent | "key" => key}
    current = Agents.instance(context, agent["name"], key)

    Agents.update_instance(context, target, %{
      "schedules" => (current["schedules"] || []) ++ [entry]
    })
  end

  defp at(context) do
    case Agents.text(context, "at") do
      "" -> from_now(context)
      text -> parse(text)
    end
  end

  defp from_now(context) do
    unit = Map.get(@units, Agents.text(context, "unit"), 86_400)

    case Float.parse(Agents.text(context, "in")) do
      {amount, ""} when amount > 0 and amount * unit <= @longest ->
        {:ok,
         DateTime.utc_now() |> DateTime.add(round(amount * unit)) |> DateTime.truncate(:second)}

      {amount, ""} when amount > 0 ->
        {:error, "A schedule goes a year ahead at most."}

      _other ->
        {:error, "In must be a number above zero, like 3."}
    end
  end

  defp parse(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} ->
        if DateTime.compare(at, DateTime.utc_now()) == :gt,
          do: {:ok, DateTime.truncate(at, :second)},
          else: {:error, "At is in the past: #{text}."}

      {:error, _reason} ->
        {:error, "At must be a date and time like 2026-12-01T09:00:00-03:00."}
    end
  end
end
