defmodule SimpleGraphqlClient.WebSocket.GraphqlTransportWs do
  @moduledoc """
    GraphQL over WebSocket Protocol (The WebSocket sub-protocol graphql-transport-ws.)
    https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md
  """
  require Logger

  @ping_sleep 15_000
  @pong_sleep 30_000
  @disconnect_sleep 30_000

  def handle_connect(conn, %{socket: socket} = state) do
    Logger.debug("(#{__MODULE__}) - Connected: #{inspect(conn)}")

    WebSockex.cast(socket, :connection_init)

    # Start a ping timer
    ping_timer = Process.send_after(self(), :ping, @ping_sleep)

    {:ok, %{state | ping_timer: ping_timer}}
  end

  def handle_disconnect(map, %{subscription_server: subscription_server} = state) do
    Logger.error("(#{__MODULE__}) - Disconnected: #{inspect(map)}")

    clean_all_timers(state)

    GenServer.cast(subscription_server, :disconnected)

    :timer.sleep(@disconnect_sleep)

    {:reconnect, %{state | subscriptions: %{}, ping_timer: nil, pong_timer: nil}}
  end

  # Client messages (graphql-transport-ws)

  #  ConnectionInit
  def handle_cast(:connection_init, %{connection_params: connection_params} = state) do
    msg =
      %{
        "type" => "connection_init",
        "payload" => connection_params
      }
      |> Jason.encode!()

    Logger.debug("(#{__MODULE__}) - ConnectionInit: #{msg}")
    {:reply, {:text, msg}, state}
  end

  #  Subscribe
  def handle_cast(
        {:subscribe, {pid, subscription_name, query, variables}},
        %{msg_ref: msg_ref} = state
      ) do
    msg =
      %{
        "id" => "#{msg_ref}",
        "type" => "subscribe",
        "payload" => %{
          "variables" => variables,
          "extensions" => %{},
          "operationName" => nil,
          "query" => query
        }
      }
      |> Jason.encode!()

    Logger.debug("(#{__MODULE__}) - Subscribe: #{msg}")

    subscriptions = Map.put(state.subscriptions, "#{msg_ref}", {pid, subscription_name})

    {:reply, {:text, msg}, %{state | subscriptions: subscriptions, msg_ref: msg_ref + 1}}
  end

  # Ping
  def handle_cast(:ping, state) do
    pong_timer = Process.send_after(self(), :pong, @pong_sleep)
    Logger.debug("(#{__MODULE__}) - Ping: #{inspect(pong_timer)}")
    {:reply, {:text, Jason.encode!(%{"type" => "ping"})}, %{state | pong_timer: pong_timer}}
  end

  #  Complete
  def handle_cast(
        {:stop, {pid, subscription_name}},
        %{subscriptions: subscriptions} = state
      ) do
    id = get_id(subscriptions, {pid, subscription_name})

    msg =
      %{
        "id" => id,
        "type" => "complete"
      }
      |> Jason.encode!()

    Logger.debug("(#{__MODULE__}) - Complete: #{msg}")

    subscriptions = Map.drop(subscriptions, [id])

    {:reply, {:text, msg}, %{state | subscriptions: subscriptions}}
  end

  def handle_cast(message, state) do
    Logger.info("(#{__MODULE__}) - Cast: #{inspect(message)}")
    {:noreply, state}
  end

  def handle_info(:pong,  %{subscription_server: subscription_server} = state) do
    Logger.warn("(#{__MODULE__}) - Pong Timeout")

    clean_all_timers(state)

    GenServer.cast(subscription_server, :disconnected)

    :timer.sleep(@disconnect_sleep)

    {:reconnect, %{state | subscriptions: %{}, ping_timer: nil, pong_timer: nil}}
  end

  def handle_info(:ping, %{socket: socket} = state) do
    WebSockex.cast(socket, :ping)

    # Start a ping timer
    ping_timer = Process.send_after(self(), :ping, @ping_sleep)

    {:ok, %{state | ping_timer: ping_timer}}
  end

  def handle_info(msg, state) do
    Logger.info("(#{__MODULE__}) Info - Message: #{inspect(msg)}")
    {:ok, state}
  end

  # Server responses (graphql-transport-ws)

  # ConnectionAck
  def handle_msg(%{"type" => "connection_ack"}, state) do
    GenServer.cast(state.subscription_server, :joined)
    Logger.debug("(#{__MODULE__}) - ConnectionAck")
    {:ok, state}
  end

  # Pong
  def handle_msg(%{"type" => "pong"}, %{pong_timer: pong_timer} = state)
      when not is_nil(pong_timer) do
    Logger.debug("(#{__MODULE__}) - Pong")
    Process.cancel_timer(pong_timer)
    {:ok, %{state | pong_timer: nil}}
  end

  def handle_msg(%{"type" => "pong"}, state) do
    Logger.debug("(#{__MODULE__}) - No requested Pong")
    {:ok, state}
  end

  # Next

  def handle_msg(
        %{"payload" => %{"data" => payload}, "id" => subscription_id, "type" => "data"} = _msg,
        %{subscriptions: subscriptions} = state
      ) do
    # Logger.debug("(#{__MODULE__}) Next - Message: #{inspect(msg)}")

    subscriptions
    |> Map.get(subscription_id)
    |> notify(payload)

    {:ok, state}
  end

  def handle_msg(
        %{
          "payload" => payload,
          "id" => subscription_id,
          "type" => "next"
        } = _msg,
        %{subscriptions: subscriptions} = state
      ) do
    # Logger.debug("(#{__MODULE__}) Next - Payload: #{inspect(msg)}")

    subscriptions
    |> Map.get(subscription_id)
    |> notify(payload)

    {:ok, state}
  end

  # Error
  def handle_msg(
        %{"payload" => payload, "id" => subscription_id, "type" => "error"} = msg,
        %{subscriptions: subscriptions} = state
      ) do
    Logger.error("(#{__MODULE__}) Error - Payload: #{inspect(msg)}")

    subscriptions
    |> Map.get(subscription_id)
    |> notify(payload)

    {:ok, state}
  end

  # Complete
  def handle_msg(%{"type" => "complete"} = msg, state) do
    Logger.debug("(#{__MODULE__}) Complete - Message: #{inspect(msg)}")
    {:ok, state}
  end

  def handle_msg(msg, state) do
    Logger.error("(#{__MODULE__}) - Msg: #{inspect(msg)}")
    {:ok, state}
  end

  defp clean_all_timers(%{ping_timer: ping_timer, pong_timer: pong_timer}) do
    for timer <- [ping_timer, pong_timer], not is_nil(timer), do: Process.cancel_timer(timer)
  end

  defp get_id(subscriptions, key) do
    Enum.find(subscriptions, {"0", 0}, fn {_key, value} -> value == key end) |> elem(0)
  end

  defp notify(nil, payload), do: Logger.error("(#{__MODULE__}) Invalid ID #{inspect(payload)}")

  defp notify({pid, subscription_name}, payload),
    do: GenServer.cast(pid, {:subscription, subscription_name, payload})
end
