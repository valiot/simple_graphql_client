# original source code at https://github.com/annkissam/absinthe_websocket/blob/master/lib/absinthe_websocket/websocket.ex
# Credentials goes to github.com/annkissam
defmodule SimpleGraphqlClient.WebSocket.GraphqlWs do
  @moduledoc """
   Simple genserver on top of WebSockex to handle WS stuff
  """
  use WebSockex
  require Logger
  alias SimpleGraphqlClient.SubscriptionServer

  @heartbeat_sleep 30_000
  @disconnect_sleep 30_000

  def start_link(args) do
    Logger.debug("(#{__MODULE__}) Websocket Init. #{inspect args}")

    ws_url = Keyword.get(args, :ws_url)
    extra_headers = Keyword.get(args, :extra_headers, [])
    connection_params = Keyword.get(args, :connection_params, [])

    state = %{
      subscriptions: %{},
      protocol: get_new_protocol(extra_headers),
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

  # graphql-ws protocol
  def handle_connect(conn, %{socket: socket, protocol: "graphql-ws"} = state) do
    Logger.debug("(#{__MODULE__}) - Connected: #{inspect(conn)}")
    WebSockex.cast(socket, :connection_init)
    {:ok, state}
  end

  # default Websocket protocol
  def handle_connect(conn, %{socket: socket} = state) do
    Logger.info("(#{__MODULE__}) - Connected: #{inspect(conn)}")

    WebSockex.cast(socket, :join)

    # Send a heartbeat
    heartbeat_timer = Process.send_after(self(), :heartbeat, @heartbeat_sleep)

    state = Map.put(state, :heartbeat_timer, heartbeat_timer)

    {:ok, state}
  end

  # graphql-ws protocol
  def handle_disconnect(map, %{protocol: "graphql-ws"} = state) do
    Logger.error("(#{__MODULE__}) - Disconnected: #{inspect(map)}")

    GenServer.cast(state.subscription_server, :disconnected)

    :timer.sleep(@disconnect_sleep)

    {:reconnect, %{state | subscriptions: %{}}}
  end

  # default Websocket protocol
  def handle_disconnect(map, %{heartbeat_timer: heartbeat_timer} = state) do
    Logger.error("(#{__MODULE__}) - Disconnected: #{inspect(map)}")

    if heartbeat_timer do
      :timer.cancel(heartbeat_timer)
    end

    state = Map.put(state, :heartbeat_timer, nil)

    :timer.sleep(@disconnect_sleep)

    GenServer.cast(state.subscription_server, :disconnected)

    {:reconnect, %{state | subscriptions: %{}}}
  end

  # Client messages (graphql-ws)

  #  GQL_CONNECTION_INIT
  def handle_cast(:connection_init, %{connection_params: connection_params} = state) do
    msg =
      %{
        "type" => "connection_init",
        "payload" => connection_params
      }
      |> Jason.encode!()

    Logger.debug("(#{__MODULE__}) - GQL_CONNECTION_INIT: #{msg}")
    {:reply, {:text, msg}, state}
  end

  #  GQL_START
  def handle_cast(
        {:subscribe, {pid, subscription_name, query, variables}},
        %{msg_ref: msg_ref, protocol: "graphql-ws"} = state
      ) do
    msg =
      %{
        "id" => "#{msg_ref}",
        "type" => "start",
        "payload" => %{
          "variables" => variables,
          "extensions" => %{},
          "operationName" => nil,
          "query" => query
        }
      }
      |> Jason.encode!()

    Logger.debug("(#{__MODULE__}) - GQL_START: #{msg}")

    subscriptions = Map.put(state.subscriptions, "#{msg_ref}", {pid, subscription_name})

    state =
      state
      |> Map.put(:subscriptions, subscriptions)
      |> Map.put(:msg_ref, msg_ref + 1)

    {:reply, {:text, msg}, state}
  end

  #  GQL_STOP
  def handle_cast(
        {:stop, {pid, subscription_name}},
        %{protocol: "graphql-ws", subscriptions: subscriptions} = state
      ) do
    id = get_id(subscriptions, {pid, subscription_name})

    msg =
      %{
        "id" => id,
        "type" => "stop"
      }
      |> Jason.encode!()

    Logger.debug("(#{__MODULE__}) - GQL_STOP: #{msg}")

    subscriptions = Map.drop(subscriptions, [id])

    {:reply, {:text, msg}, %{state | subscriptions: subscriptions}}
  end

  #  GQL_CONNECTION_TERMINATE
  def handle_cast(
        {:connection_terminate, pid},
        %{protocol: "graphql-ws"} = state
      ) do
    msg = %{"type" => "connection_terminate"} |> Jason.encode!()

    Logger.debug("(#{__MODULE__}) - GQL_CONNECTION_TERMINATE: #{msg}")
    GenServer.cast(pid, :disconnected)

    {:reply, {:text, msg}, %{state | subscriptions: %{}}}
  end

  # Client messages (default Websocket protocol)

  def handle_cast(:join, %{queries: queries, msg_ref: msg_ref} = state) do
    msg =
      %{
        topic: "__absinthe__:control",
        event: "phx_join",
        payload: %{},
        ref: msg_ref
      }
      |> Jason.encode!()

    queries = Map.put(queries, msg_ref, :join)

    state =
      state
      |> Map.put(:queries, queries)
      |> Map.put(:msg_ref, msg_ref + 1)

    {:reply, {:text, msg}, state}
  end

  # Heartbeat: http://graemehill.ca/websocket-clients-and-phoenix-channels/
  # https://stackoverflow.com/questions/34948331/how-to-implement-a-resetable-countdown-timer-with-a-genserver-in-elixir-or-erlan
  def handle_cast(:heartbeat, %{queries: queries, msg_ref: msg_ref} = state) do
    msg =
      %{
        topic: "phoenix",
        event: "heartbeat",
        payload: %{},
        ref: msg_ref
      }
      |> Jason.encode!()

    queries = Map.put(queries, msg_ref, :heartbeat)

    state =
      state
      |> Map.put(:queries, queries)
      |> Map.put(:msg_ref, msg_ref + 1)

    {:reply, {:text, msg}, state}
  end

  def handle_cast(
        {:query, {pid, ref, query, variables}},
        %{queries: queries, msg_ref: msg_ref} = state
      ) do
    doc = %{
      "query" => query,
      "variables" => variables
    }

    msg =
      %{
        topic: "__absinthe__:control",
        event: "doc",
        payload: doc,
        ref: msg_ref
      }
      |> Jason.encode!()

    queries = Map.put(queries, msg_ref, {:query, pid, ref})

    state =
      state
      |> Map.put(:queries, queries)
      |> Map.put(:msg_ref, msg_ref + 1)

    {:reply, {:text, msg}, state}
  end

  def handle_cast(
        {:subscribe, {pid, subscription_name, query, variables}},
        %{queries: queries, msg_ref: msg_ref} = state
      ) do
    doc = %{
      "query" => query,
      "variables" => variables
    }

    msg =
      %{
        topic: "__absinthe__:control",
        event: "doc",
        payload: doc,
        ref: msg_ref
      }
      |> Jason.encode!()

    queries = Map.put(queries, msg_ref, {:subscribe, pid, subscription_name})

    state =
      state
      |> Map.put(:queries, queries)
      |> Map.put(:msg_ref, msg_ref + 1)

    {:reply, {:text, msg}, state}
  end

  def handle_info(:heartbeat, %{socket: socket} = state) do
    WebSockex.cast(socket, :heartbeat)

    # Send another heartbeat
    heartbeat_timer = Process.send_after(self(), :heartbeat, @heartbeat_sleep)
    state = Map.put(state, :heartbeat_timer, heartbeat_timer)

    {:ok, state}
  end

  def handle_info(msg, state) do
    Logger.info("(#{__MODULE__}) Info - Message: #{inspect(msg)}")
    {:ok, state}
  end

  # Server responses (graphql-ws)

  # GQL_CONNECTION_ERROR
  def handle_msg(%{"type" => "connection_error"} = msg, state) do
    Logger.error("(#{__MODULE__}) GQL_CONNECTION_ERROR - Message: #{inspect(msg)}")
    {:ok, state}
  end

  # GQL_CONNECTION_ACK
  def handle_msg(%{"type" => "connection_ack"}, state) do
    GenServer.cast(state.subscription_server, :joined)
    Logger.debug("(#{__MODULE__}) - GQL_CONNECTION_ACK")
    {:ok, state}
  end

  # GQL_DATA
  def handle_msg(
        %{
          "payload" => %{"data" => payload, "error" => errors},
          "id" => subscription_id,
          "type" => "data"
        } = msg,
        %{subscriptions: subscriptions} = state
      ) do

    Logger.debug("(#{__MODULE__}) GQL_DATA - Message: #{inspect(msg)}")
    Logger.error("(#{__MODULE__}) GQL_DATA - Message: #{inspect(errors)}")

    subscriptions
    |> Map.get(subscription_id)
    |> notify(payload)

    {:ok, state}
  end

  def handle_msg(
        %{"payload" => %{"data" => payload}, "id" => subscription_id, "type" => "data"} = _msg,
        %{subscriptions: subscriptions} = state
      ) do
    #Logger.debug("(#{__MODULE__}) GQL_DATA - Message: #{inspect(msg)}")

    subscriptions
    |> Map.get(subscription_id)
    |> notify(payload)

    {:ok, state}
  end

  def handle_msg(
        %{"payload" => payload, "id" => subscription_id, "type" => "data"} = _msg,
        %{subscriptions: subscriptions} = state
      ) do

    #Logger.debug("(#{__MODULE__}) GQL_DATA - Message: #{inspect(msg)}")

    subscriptions
    |> Map.get(subscription_id)
    |> notify(payload)

    {:ok, state}
  end

  # GQL_ERROR
  def handle_msg(
        %{"payload" => payload, "id" => subscription_id, "type" => "error"} = msg,
        %{subscriptions: subscriptions} = state
      ) do

    Logger.error("(#{__MODULE__}) GQL_ERROR - Message: #{inspect(msg)}")

    subscriptions
    |> Map.get(subscription_id)
    |> notify(payload)

    {:ok, state}
  end

  # GQL_COMPLETE
  def handle_msg(%{"type" => "complete"} = msg, state) do
    Logger.debug("(#{__MODULE__}) GQL_COMPLETE - Message: #{inspect(msg)}")
    {:ok, state}
  end

  # GQL_CONNECTION_KEEP_ALIVE
  def handle_msg(%{"type" => "ka"}, state) do
    Logger.debug("(#{__MODULE__}) - GQL_CONNECTION_KEEP_ALIVE")
    {:ok, state}
  end


  # Server responses (default Websocket protocol)

  def handle_msg(%{"event" => "phx_reply", "payload" => payload, "ref" => msg_ref} = msg, state) do
    Logger.info("(#{__MODULE__}) Info - Message: #{inspect(msg)}")
    queries = state.queries
    {command, queries} = Map.pop(queries, msg_ref)
    state = Map.put(state, :queries, queries)

    status = payload["status"] |> String.to_atom()

    state =
      case command do
        {:query, pid, ref} ->
          case status do
            :ok ->
              data = payload["response"]["data"]
              GenServer.cast(pid, {:query_response, ref, {status, data}})

            :error ->
              errors = payload["response"]["errors"]
              GenServer.cast(pid, {:query_response, ref, {status, errors}})
          end

          state

        {:subscribe, pid, subscription_name} ->
          unless status == :ok do
            raise "Subscription Error - #{inspect(payload)}"
          end

          subscription_id = payload["response"]["subscriptionId"]
          subscriptions = Map.put(state.subscriptions, subscription_id, {pid, subscription_name})
          Map.put(state, :subscriptions, subscriptions)

        :join ->
          unless status == :ok do
            raise "Join Error - #{inspect(payload)}"
          end

          Logger.debug("(#{__MODULE__}) - Join: #{inspect(msg)}")

          GenServer.cast(state.subscription_server, :joined)

          state

        :heartbeat ->
          unless status == :ok do
            raise "Heartbeat Error - #{inspect(payload)}"
          end

          state
      end

    {:ok, state}
  end

  def handle_msg(
        %{"event" => "subscription:data", "payload" => payload, "topic" => subscription_id} = msg,
        %{subscriptions: subscriptions} = state
      ) do
    {pid, subscription_name} = Map.get(subscriptions, subscription_id)
    Logger.info("(#{__MODULE__}) Info - Message: #{inspect(msg)}")

    data = payload["result"]["data"]

    GenServer.cast(pid, {:subscription, subscription_name, data})

    {:ok, state}
  end

  def handle_msg(msg, state) do
    Logger.error("(#{__MODULE__}) - Msg: #{inspect(msg)}")
    {:ok, state}
  end

  def handle_frame({:text, msg}, state) do
    msg =
      msg
      |> Jason.decode!()

    handle_msg(msg, state)
  end

  def get_new_protocol(extra_headers) do
    Enum.reduce(extra_headers, nil, fn {key, value}, acc ->
      if key == "Sec-WebSocket-Protocol",
        do: value,
        else: acc
    end)
  end

  defp get_id(subscriptions, key) do
    Enum.find(subscriptions, {"0", 0}, fn {_key, value} -> value == key end) |> elem(0)
  end

  defp notify(nil, payload), do: Logger.error("(#{__MODULE__}) Invalid ID #{inspect(payload)}")
  defp notify({pid, subscription_name}, payload), do: GenServer.cast(pid, {:subscription, subscription_name, payload})

  # def handle_cast(message, state) do
  #   Logger.info("(#{__MODULE__}) - Cast: #{inspect(message)}")
  #   super(message, state)
  # end
end
