defmodule SimpleGraphqlClient.SubscriptionServer do
  @moduledoc "
    Genserver that handles all subscription related logic
  "
  use GenServer
  require Logger
  alias SimpleGraphqlClient.WebSocket

  def start_link do
    state = %{
      socket: WebSocket,
      subscriptions: %{},
      queries: %{}
    }

    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  def subscribe(subscription_name, callback_or_dest, query, variables \\ []) do
    GenServer.cast(
      __MODULE__,
      {:subscribe, subscription_name, callback_or_dest, query, variables}
    )
  end

  def handle_cast(
        {:subscribe, subscription_name, callback_or_dest, query, variables},
        %{socket: socket, subscriptions: subscriptions, queries: queries} = state
      ) do
    actual_suscriptions = Map.keys(subscriptions)

    unless subscription_name in actual_suscriptions,
      do: WebSocket.subscribe(socket, self(), subscription_name, query, variables)

    callbacks = Map.get(subscriptions, subscription_name, [])

    subscriptions =
      unless callback_or_dest in callbacks,
        do: Map.put(subscriptions, subscription_name, [callback_or_dest | callbacks]),
        else: subscriptions

    queries = Map.put(queries, subscription_name, [query, variables])
    state = Map.put(state, :subscriptions, subscriptions)

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
    Enum.each(queries, fn {subscription_name, [query, variables]} ->
      WebSocket.subscribe(socket, self(), subscription_name, query, variables)
    end)

    {:noreply, state}
  end

  defp handle_callback_or_dest(callback_or_dest, response) do
    if is_function(callback_or_dest) do
      callback_or_dest.(response)
    else
      send(callback_or_dest, {:subscription, response})
    end
  end
end
