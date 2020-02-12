defmodule SimpleGraphqlClient.SubscriptionServer do
  @moduledoc "
    Genserver that handles all subscription related logic
  "
  use GenServer
  require Logger
  alias SimpleGraphqlClient.WebSocket

  defstruct socket: WebSocket,
            subscriptions: %{},
            connected?: false,
            queries: %{}

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    {:ok, %__MODULE__{}}
  end

  def subscribe(subscription_name, callback_or_dest, query, variables \\ []) do
    GenServer.cast(
      __MODULE__,
      {:subscribe, subscription_name, callback_or_dest, query, variables}
    )
  end

  def unsubscribe(subscription_name) do
    GenServer.cast(__MODULE__, {:unsubscribe, subscription_name})
  end

  def restart_websocket() do
    GenServer.cast(__MODULE__, :restart_websocket)
  end

  # WIP
  # def query(subscription_name, callback_or_dest, query, variables \\ []) do
  #   GenServer.cast(
  #     __MODULE__,
  #     {:query, subscription_name, callback_or_dest, query, variables}
  #   )
  # end

  def handle_cast(
        {:subscribe, subscription_name, callback_or_dest, query, variables},
        %{socket: socket, subscriptions: subscriptions, queries: queries, connected?: connected?} =
          state
      ) do
    actual_suscriptions = Map.keys(subscriptions)

    # Sends subscription message if the websocket is connected and is a new subscription request.
    if subscription_name not in actual_suscriptions and connected?,
      do: WebSocket.subscribe(socket, self(), subscription_name, query, variables)

    callbacks = Map.get(subscriptions, subscription_name, [])

    subscriptions =
      unless callback_or_dest in callbacks,
        do: Map.put(subscriptions, subscription_name, [callback_or_dest | callbacks]),
        else: subscriptions

    queries = Map.put(queries, subscription_name, [query, variables])

    {:noreply, %{state | queries: queries, subscriptions: subscriptions}}
  end

  # Incoming Notifications (from SimpleGraphqlClient.WebSocket)
  def handle_cast(
        {:subscription, subscription_name, response},
        %{subscriptions: subscriptions} = state
      ) do
    subscriptions
    |> Map.get(subscription_name, [])
    |> Enum.each(fn callback_or_dest -> handle_callback_or_dest(callback_or_dest, response) end)

    {:noreply, state}
  end

  def handle_cast(:joined, %{socket: socket, queries: queries} = state) do
    # Resend subscription request.
    Logger.debug("(#{__MODULE__}) Resending Subscriptions")

    Enum.each(queries, fn {subscription_name, [query, variables]} ->
      WebSocket.subscribe(socket, self(), subscription_name, query, variables)
    end)

    {:noreply, %{state | connected?: true}}
  end

  def handle_cast(:disconnected, state) do
    Logger.debug("(#{__MODULE__}) Disconnected")
    {:noreply, %{state | connected?: false}}
  end

  def handle_cast(
        {:unsubscribe, subscription_name},
        %{queries: queries, subscriptions: subs, socket: socket} = state
      ) do
    queries = Map.drop(queries, [subscription_name])
    subs = Map.drop(subs, [subscription_name])
    WebSocket.unsubscribe(socket, self(), subscription_name)
    {:noreply, %{state | queries: queries, subscriptions: subs}}
  end

  def handle_cast(:restart_websocket, %{socket: socket}) do
    WebSocket.connection_terminate(socket, self())
    {:noreply, %__MODULE__{}}
  end

  defp handle_callback_or_dest(callback_or_dest, response) do
    if is_function(callback_or_dest) do
      callback_or_dest.(response)
    else
      send(callback_or_dest, {:subscription, response})
    end
  end
end
