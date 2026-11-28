defmodule HeddleIntegrations.Agents.Bridge do
  @moduledoc """
  Runs Jido's reasoning for a node, while the node's own process does what reaches
  Heddle: each model call and each tool.

  Jido calls the model and the tools from processes of its own. What Heddle does for a
  node is kept in the node's process, like what each step costs and which runs led to
  this one, which stops agents from calling each other forever. So `run/4` starts the
  reasoning in a task and answers its calls until it ends. The processes Jido starts
  find the node's process among their callers (`$callers`), where it is registered.

  The API key is only in that process too: Jido never holds it, so it isn't in what an
  agent keeps between runs.
  """

  @timeout :timer.minutes(10)

  @doc """
  Calls `fun`, which runs Jido, and answers its calls: a model call with `connection`
  (`%{model, options}`, from `Bobbin.Host.ai_connection/2`), and a tool with `call`.
  Returns what `fun` returned, or `{:error, message}`.
  """
  def run(fun, connection, call, opts \\ []) do
    ref = make_ref()
    {:ok, _owner} = Registry.register(__MODULE__, self(), ref)

    try do
      task = Task.Supervisor.async_nolink(HeddleIntegrations.Agents.Tasks, fun)
      serve(task, ref, connection, call, Keyword.get(opts, :timeout, @timeout))
    after
      Registry.unregister(__MODULE__, self())
    end
  end

  defp serve(task, ref, connection, call, timeout) do
    receive do
      {^ref, from, reply, request} ->
        send(from, {reply, answer(request, connection, call)})
        serve(task, ref, connection, call, timeout)

      {task_ref, result} when task_ref == task.ref ->
        Process.demonitor(task_ref, [:flush])
        result

      {:DOWN, task_ref, :process, _pid, reason} when task_ref == task.ref ->
        {:error, "The agent stopped: #{Exception.format_exit(reason)}"}
    after
      timeout ->
        Task.shutdown(task, :brutal_kill)
        {:error, "The agent took longer than #{div(timeout, 60_000)} minutes."}
    end
  end

  defp answer({:generate_text, context, options}, connection, _call) do
    options = Keyword.merge(options, connection.options)

    case model().generate_text(connection.model, context, options) do
      {:ok, response} = ok ->
        Bobbin.Host.record_usage(ReqLLM.Response.usage(response) || %{})
        ok

      {:error, _reason} = error ->
        error
    end
  end

  defp answer({:tool, name, arguments}, _connection, call), do: call.(name, arguments)

  @doc """
  Asks the node's process for `request`, from a process Jido started. Answers
  `{:error, ...}` when no node started it.
  """
  def ask(request) do
    case owner() do
      {pid, ref} ->
        reply = make_ref()
        monitor = Process.monitor(pid)
        send(pid, {ref, self(), reply, request})

        receive do
          {^reply, answer} ->
            Process.demonitor(monitor, [:flush])
            answer

          {:DOWN, ^monitor, :process, _pid, _reason} ->
            {:error, "The node running the agent stopped."}
        end

      nil ->
        {:error, "The agent runs only inside a node of a flow."}
    end
  end

  defp owner do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case Registry.lookup(__MODULE__, pid) do
        [{^pid, ref}] -> {pid, ref}
        [] -> nil
      end
    end)
  end

  # ReqLLM, or what a test puts in its place.
  defp model, do: Application.get_env(:heddle_jido, :model_client, ReqLLM)
end
