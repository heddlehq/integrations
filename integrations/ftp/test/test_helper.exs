Application.put_env(:bobbin, :host, Bobbin.TestHost)
Application.put_env(:bobbin, :req_plug, {Req.Test, HeddleIntegrations.Nodes.HttpRequest})

ExUnit.start(exclude: [:databases])
