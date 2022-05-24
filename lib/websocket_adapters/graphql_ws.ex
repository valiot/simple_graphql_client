# original source code at https://github.com/annkissam/absinthe_websocket/blob/master/lib/absinthe_websocket/websocket.ex
# Credentials goes to github.com/annkissam
defmodule SimpleGraphqlClient.WebSocket.GraphqlWs do
  @moduledoc """
   Simple genserver on top of WebSockex to handle WS stuff
  """
  require Logger

  @disconnect_sleep 30_000

  def handle_connect(conn, %{socket: socket} = state) do
    Logger.debug("(#{__MODULE__}) - Connected: #{inspect(conn)}")
    WebSockex.cast(socket, :connection_init)
    {:ok, state}
  end

  def handle_disconnect(map, %{subscription_server: subscription_server} = state) do
    Logger.error("(#{__MODULE__}) - Disconnected: #{inspect(map)}")

    GenServer.cast(subscription_server, :disconnected)

    :timer.sleep(@disconnect_sleep)

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
        %{msg_ref: msg_ref} = state
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
        %{subscriptions: subscriptions} = state
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
        state
      ) do
    msg = %{"type" => "connection_terminate"} |> Jason.encode!()

    Logger.debug("(#{__MODULE__}) - GQL_CONNECTION_TERMINATE: #{msg}")
    GenServer.cast(pid, :disconnected)

    {:reply, {:text, msg}, %{state | subscriptions: %{}}}
  end

  def handle_cast(message, state) do
    Logger.info("(#{__MODULE__}) - Cast: #{inspect(message)}")
    {:noreply, state}
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

  def handle_msg(msg, state) do
    Logger.error("(#{__MODULE__}) - Msg: #{inspect(msg)}")
    {:ok, state}
  end

  defp get_id(subscriptions, key) do
    Enum.find(subscriptions, {"0", 0}, fn {_key, value} -> value == key end) |> elem(0)
  end

  defp notify(nil, payload), do: Logger.error("(#{__MODULE__}) Invalid ID #{inspect(payload)}")
  defp notify({pid, subscription_name}, payload), do: GenServer.cast(pid, {:subscription, subscription_name, payload})
end
