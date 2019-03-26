defmodule RigInboundGatewayWeb.V1.Websocket do
  @moduledoc """
  Cowboy WebSocket handler.

  As soon as Phoenix pulls in Cowboy 2 this will have to be rewritten using the
  :cowboy_websocket behaviour.
  """

  require Logger

  alias Jason

  alias Result

  alias Rig.EventFilter
  alias RigCloudEvents.CloudEvent
  alias RigInboundGateway.Events
  alias RigInboundGatewayWeb.ConnectionInit

  @behaviour :cowboy_websocket

  @heartbeat_interval_ms 15_000
  @subscription_refresh_interval_ms 60_000

  # ---

  @impl :cowboy_websocket
  def init(req, :ok) do
    query_params = req |> :cowboy_req.parse_qs() |> Enum.into(%{})

    # The initialization is done in the websocket handler, which is a different process.

    # Upgrade the connection to WebSocket protocol:
    state = %{query_params: query_params}
    opts = %{idle_timeout: :infinity}
    {:cowboy_websocket, req, state, opts}
  end

  # ---

  @impl :cowboy_websocket
  def websocket_init(%{query_params: query_params} = state) do
    on_success = fn subscriptions ->
      # Say "hi", enter the loop and wait for cloud events to forward to the client:
      state = %{subscriptions: subscriptions}
      {:reply, frame(Events.welcome_event()), state, :hibernate}
    end

    on_error = fn reason ->
      # WebSocket close frames may include a payload to indicate the error, but we found
      # that error message must be really short; if it isn't, the `{:close, :normal,
      # payload}` is silently converted to `{:close, :abnormal, nil}`. Since there is no
      # limit mentioned in the spec (RFC-6455), we opt for consistent responses,
      # omitting the detailed error.
      Logger.warn(fn -> "WS conn failed: #{reason}" end)
      reason = "Bad request."
      # This will close the connection:
      {:reply, closing_frame(reason), state}
    end

    ConnectionInit.set_up(
      "WS",
      query_params,
      on_success,
      on_error,
      @heartbeat_interval_ms,
      @subscription_refresh_interval_ms
    )
  end

  # ---

  @doc ~S"The client may send this as the response to the :ping heartbeat."
  @impl :cowboy_websocket
  def websocket_handle({:pong, _}, state), do: {:ok, state, :hibernate}
  @impl :cowboy_websocket
  def websocket_handle(:pong, state), do: {:ok, state, :hibernate}

  @impl :cowboy_websocket
  def websocket_handle(in_frame, state) do
    Logger.debug(fn -> "Unexpected WebSocket input: #{inspect(in_frame)}" end)
    # This will close the connection:
    {:reply, closing_frame("This WebSocket endpoint cannot be used for two-way communication."),
     state}
  end

  # ---

  @impl :cowboy_websocket
  def websocket_info(:heartbeat, state) do
    # Schedule the next heartbeat:
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    # Ping the client to keep the connection alive:
    {:reply, :ping, state, :hibernate}
  end

  @impl :cowboy_websocket
  def websocket_info(%CloudEvent{} = event, state) do
    Logger.debug(fn -> inspect(event) end)
    # Forward the event to the client:
    {:reply, frame(event), state, :hibernate}
  end

  @impl :cowboy_websocket
  def websocket_info({:set_subscriptions, subscriptions}, state) do
    Logger.debug(fn -> inspect(subscriptions) end)
    # Trigger immediate refresh:
    EventFilter.refresh_subscriptions(subscriptions, state.subscriptions)
    # Replace current subscriptions:
    state = Map.put(state, :subscriptions, subscriptions)
    # Notify the client:
    {:reply, frame(Events.subscriptions_set(subscriptions)), state, :hibernate}
  end

  @impl :cowboy_websocket
  def websocket_info(:refresh_subscriptions, state) do
    EventFilter.refresh_subscriptions(state.subscriptions, [])
    Process.send_after(self(), :refresh_subscriptions, @subscription_refresh_interval_ms)
    {:ok, state}
  end

  @impl :cowboy_websocket
  def websocket_info({:session_killed, group}, state) do
    Logger.info("session killed: #{inspect(group)}")
    # This will close the connection:
    {:reply, closing_frame("Session killed."), state}
  end

  # ---

  defp frame(%CloudEvent{json: json}) do
    {:text, json}
  end

  # ---

  defp closing_frame(reason) do
    # Sending this will close the connection:
    {
      :close,
      # "Normal Closure":
      1_000,
      reason
    }
  end
end
