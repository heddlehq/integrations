# Checks every manifest and writes the index Heddle reads.
#
#     elixir scripts/build.exs [OUT_DIR]
#
# Each integration lives in integrations/<id>/integration.yaml, and its folder must be
# named after its id. The index holds the manifest itself, so an installed version
# stays the same even after the folder changes.
Mix.install([{:bobbin, "~> 0.5"}])

out = List.first(System.argv()) || "_site"
paths = Path.wildcard("integrations/*/integration.yaml") |> Enum.sort()

{entries, errors} =
  Enum.reduce(paths, {[], []}, fn path, {entries, errors} ->
    folder = path |> Path.dirname() |> Path.basename()
    yaml = File.read!(path)

    case Bobbin.Integration.parse(yaml) do
      {:ok, %{id: ^folder} = integration} ->
        map = YamlElixir.read_from_string!(yaml)

        entry = %{
          id: integration.id,
          name: integration.name,
          version: integration.version,
          description: integration.description,
          icon: integration.icon,
          author: map["author"],
          homepage: map["homepage"],
          actions: Enum.map(integration.actions, & &1.name),
          triggers: Enum.map(integration.triggers, & &1.name),
          sha256: :crypto.hash(:sha256, yaml) |> Base.encode16(case: :lower),
          manifest: yaml
        }

        {[entry | entries], errors}

      {:ok, integration} ->
        {entries, ["#{path}: the folder must be named #{integration.id}" | errors]}

      {:error, messages} ->
        {entries, ["#{path}:\n  " <> Enum.join(messages, "\n  ") | errors]}
    end
  end)

if errors != [] do
  IO.puts(:stderr, Enum.join(Enum.reverse(errors), "\n"))
  System.halt(1)
end

File.mkdir_p!(out)
index = %{format: 1, integrations: Enum.reverse(entries)}
File.write!(Path.join(out, "index.json"), JSON.encode!(index))
IO.puts("#{length(entries)} integrations, written to #{out}/index.json")
