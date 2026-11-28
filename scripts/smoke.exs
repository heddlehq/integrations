# Runs every action and trigger of a manifest against a stub, with sample values, and
# prints the request each one sends, so you can read them before trying the service.
# Flags {{fields.x}} that name no field of the action.
#
#   elixir scripts/smoke.exs integrations/acme/integration.yaml [--quiet]
#
# BOBBIN_PATH points at a Bobbin checkout, to try a change in both at once.
Mix.install([
  case System.get_env("BOBBIN_PATH") do
    nil -> {:bobbin, "~> 0.6"}
    path -> {:bobbin, path: path}
  end,
  {:plug, "~> 1.16"}
])

[path | flags] = System.argv()
quiet = "--quiet" in flags
integration = Bobbin.Integration.load!(path)
alias Bobbin.Integration.Request

refs = fn term ->
  term |> inspect(limit: :infinity, printable_limit: :infinity)
  |> then(&Regex.scan(~r/\{\{\s*fields\.([A-Za-z0-9_]+)/, &1, capture: :all_but_first))
  |> List.flatten() |> Enum.uniq()
end

{:ok, file_ref} = Bobbin.Files.store("hello", %{"name" => "hello.txt", "mime" => "text/plain"})

sample = fn
  %{type: "number"} -> 7
  %{type: "boolean"} -> true
  %{type: "json"} -> ~s({"k": "v"})
  %{type: "datetime"} -> "2026-01-31T09:00:00Z"
  %{type: "file"} -> %{"file" => file_ref}
  %{type: t, options: [%{"value" => v} | _]} when t in ["select", "multiselect"] -> v
  %{type: t, options: [%{value: v} | _]} when t in ["select", "multiselect"] -> v
  %{name: name} -> "#{name}_v"
end

cred_sample = fn
  %{default: d} when is_binary(d) and d != "" -> d
  %{name: n} -> if n =~ ~r/url/, do: "https://svc.test", else: if(n =~ ~r/domain|host|region|shop|instance|subdomain|account|site/, do: "acme", else: String.replace(n, "_", "") <> "c")
end
credential = Map.new(integration.credential.fields, &{&1.name, cred_sample.(&1)}) |> Map.put("access_token", "tok")

plug = fn conn ->
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  send(self(), {:req, conn.method, conn.request_path, conn.query_string, body})
  conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, "{}")
end

problems =
  for kind <- [:actions, :triggers], item <- Map.get(integration, kind), reduce: 0 do
    acc ->
      names = Enum.map(item.fields, & &1.name)
      templates = [item.request, item.output, Map.get(item, :webhook)] ++ Enum.map(item.fields, &Map.get(&1, :options_from))
      missing = refs.(templates) -- names
      fields = Map.new(item.fields, &{&1.name, sample.(&1)})

      result =
        cond do
          kind == :actions -> Request.run(integration, item.name, fields, credential, plug: plug)
          item.request -> Request.poll(integration, item.name, fields, credential, plug: plug)
          true -> Bobbin.Integration.Webhook.register(integration, item.name, fields, credential, %{"url" => "https://heddle.test/hooks/tok", "secret" => "sec"}, plug: plug)
        end

      sent = receive do {:req, m, p, q, b} -> "#{m} #{p}#{if q != "", do: "?" <> q} #{String.slice(b, 0, 160)}" after 0 -> "(nothing sent)" end
      result = with {:error, m} <- result, do: if(m =~ "must return a list", do: :stubbed, else: result)
      bad = missing != [] or match?({:error, _}, result)
      if bad or not quiet, do: IO.puts("#{if bad, do: "!! ", else: ""}#{item.name}: #{sent}")
      if missing != [], do: IO.puts("   unknown fields: #{Enum.join(missing, ", ")}")
      if match?({:error, _}, result), do: IO.puts("   error: #{inspect(elem(result, 1))}")
      if bad, do: acc + 1, else: acc
  end

IO.puts("#{integration.id}: #{length(integration.actions)} actions, #{length(integration.triggers)} triggers, #{problems} problems")
