defmodule SimpleGraphqlClient.WebSocketAdapter do
  @moduledoc """
    Simple genserver on top of WebSockex to handle WS stuff, exchanging protocol management.
  """
  use WebSockex
  require Logger
  alias SimpleGraphqlClient.SubscriptionServer
  alias SimpleGraphqlClient.WebSocket.{PhoenixChannel, GraphqlWs, GraphqlTransportWs}

  defmodule State do
    @moduledoc false
    defstruct subscriptions: %{},
              protocol_handler: nil,
              connection_params: nil,
              queries: %{},
              msg_ref: 0,
              heartbeat_timer: nil,
              ping_timer: nil,
              pong_timers: [],
              socket: nil,
              subscription_server: nil
  end

  def start_link(args) do
    Logger.debug("(#{__MODULE__}) Websocket Init. #{inspect(args)}")

    ws_url = Keyword.get(args, :ws_url)
    extra_headers = Keyword.get(args, :extra_headers, [])
    connection_params = Keyword.get(args, :connection_params, [])

    state = %State{
      subscriptions: %{},
      protocol_handler: get_protocol_handler(extra_headers),
      connection_params: connection_params,
      queries: %{},
      msg_ref: 0,
      heartbeat_timer: nil,
      socket: __MODULE__,
      subscription_server: SubscriptionServer
    }

    WebSockex.start_link(ws_url, __MODULE__, state,
      handle_initial_conn_failure: true,
      async: true,
      extra_headers: extra_headers,
      name: __MODULE__
    )
  end

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, args}
    }
  end

  def query(socket, pid, ref, query, variables \\ []) do
    WebSockex.cast(socket, {:query, {pid, ref, query, variables}})
  end

  def subscribe(socket, pid, subscription_name, query, variables \\ []) do
    WebSockex.cast(socket, {:subscribe, {pid, subscription_name, query, variables}})
  end

  def unsubscribe(socket, pid, subscription_name) do
    WebSockex.cast(socket, {:stop, {pid, subscription_name}})
  end

  def connection_terminate(socket, pid) do
    WebSockex.cast(socket, {:connection_terminate, pid})
  end

  def handle_connect(conn, %{protocol_handler: protocol_handler} = state),
    do: protocol_handler.handle_connect(conn, state)

  def handle_disconnect(conn, %{protocol_handler: protocol_handler} = state),
    do: protocol_handler.handle_disconnect(conn, state)

  def handle_msg(msg, %{protocol_handler: protocol_handler} = state),
    do: protocol_handler.handle_msg(msg, state)

  def handle_cast(cast_msg, %{protocol_handler: protocol_handler} = state),
    do: protocol_handler.handle_cast(cast_msg, state)

  def handle_info(info_msg, %{protocol_handler: protocol_handler} = state),
    do: protocol_handler.handle_info(info_msg, state)


  def handle_frame({:text, msg}, state) do
    msg =
      msg
      |> Jason.decode!()

    handle_msg(msg, state)
  end

  defp get_protocol_handler(extra_headers) do
    Enum.reduce(extra_headers, nil, fn {key, value}, acc ->
      if key == "Sec-WebSocket-Protocol" do
        case value do
          "graphql-ws" -> GraphqlWs
          "graphql-transport-ws" -> GraphqlTransportWs
          "phoenix" -> PhoenixChannel
          _ -> PhoenixChannel
        end
      else
        acc
      end
    end)
  end
end
