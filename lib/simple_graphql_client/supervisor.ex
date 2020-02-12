defmodule SimpleGraphqlClient.Supervisor do
  @moduledoc """
    Supervisor for WS related genservers
  """
  use Supervisor
  alias SimpleGraphqlClient.SubscriptionServer
  alias SimpleGraphqlClient.WebSocket

  def start_link(args \\ %{}) do
    Supervisor.start_link(__MODULE__, args, name: :simple_graphql_client_supervisor)
  end

  def init(args) do
    ws_url = Keyword.get(args, :ws_url)
    extra_headers = Keyword.get(args, :extra_headers, [])
    connection_params = Keyword.get(args, :connection_params, [])

    children = [
      worker(SubscriptionServer, []),
      worker(WebSocket, [
        [ws_url: ws_url, extra_headers: extra_headers, connection_params: connection_params]
      ])
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
