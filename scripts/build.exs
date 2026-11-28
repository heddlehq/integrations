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

# Every folder, manifest or package, has its entry in catalog.yaml, and the catalog
# names each integration once.
catalog = YamlElixir.read_from_file!("catalog.yaml")["integrations"]
ids = Enum.map(catalog, & &1["id"])
statuses = ~w(planned draft community official)

catalog_errors =
  Enum.map(ids -- Enum.uniq(ids), &"catalog.yaml: #{&1} is listed twice") ++
    for(
      %{"id" => id, "status" => status} <- catalog,
      status not in statuses,
      do: "catalog.yaml: #{id} has an unknown status, #{status}"
    ) ++
    for(
      folder <- "integrations/*" |> Path.wildcard() |> Enum.filter(&File.dir?/1),
      id = Path.basename(folder),
      id not in ids,
      do: "#{folder}: add it to catalog.yaml"
    )

errors = Enum.reverse(catalog_errors) ++ errors

if errors != [] do
  IO.puts(:stderr, Enum.join(Enum.reverse(errors), "\n"))
  System.halt(1)
end

File.mkdir_p!(out)
index = %{format: 1, integrations: Enum.reverse(entries)}
File.write!(Path.join(out, "index.json"), JSON.encode!(index))
IO.puts("#{length(entries)} integrations, written to #{out}/index.json")

progress = catalog |> Enum.frequencies_by(& &1["status"])
IO.puts("Catalog: " <> Enum.map_join(statuses, ", ", &"#{progress[&1] || 0} #{&1}"))
