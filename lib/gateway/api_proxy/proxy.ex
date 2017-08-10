defmodule Gateway.ApiProxy.Proxy do
  @moduledoc """
  Provides middleware proxy for incoming REST requests at specific routes.
  Matches all incoming HTTP requests and checks if such route is defined in json file.
  If route needs authentication it is automatically triggered.
  Valid HTTP requests are forwarded to given service an their response is sent back to client.
  """
  use Plug.Router

  alias Plug.Conn.Query
  alias Gateway.ApiProxy.Base
  alias Gateway.Utils.Jwt
  alias Gateway.Kafka

  @typep route_map :: %{required(String.t) => String.t}

  plug :match
  plug :dispatch

  # Get all incoming HTTP requests, check if they are valid, provide authentication if needed
  match _ do
    %{method: method, request_path: request_path} = conn

    # Load proxy routes during the runtime
    proxy_file_location = Application.fetch_env!(:gateway, :proxy_route_config)

    :gateway
    |> :code.priv_dir
    |> Path.join(proxy_file_location)
    |> File.read!
    |> Poison.decode!
    |> Enum.find(fn(route) ->
      match_path(route, request_path) && match_http_method(route, method)
    end)
    |> check_and_forward_request(conn)
  end

  # Match route path against requested path
  @spec match_path(route_map, String.t) :: boolean
  defp match_path(route, request_path) do
    # Replace wildcards with actual params
    replace_wildcards = String.replace(route["path"], "{id}", "[^/]+")
    # Match requested path against regex
    String.match?(request_path, ~r/#{replace_wildcards}$/)
  end

  # Match route method against requested method
  @spec match_http_method(route_map, String.t) :: boolean
  defp match_http_method(route, method), do: route["method"] == method

  # Encode custom error messages with Poison to JSON format
  @type json_message :: %{message: String.t}
  @spec encode_error_message(String.t) :: json_message
  defp encode_error_message(message) do
    Poison.encode!(%{message: message})
  end

  # Handle unsupported route
  @spec check_and_forward_request(nil, %Plug.Conn{}) :: %Plug.Conn{}
  defp check_and_forward_request(nil, conn) do
    send_resp(conn, 404, encode_error_message("Route is not available"))
  end
  # Authentication required
  @spec check_and_forward_request(route_map, %Plug.Conn{}) :: %Plug.Conn{}
  defp check_and_forward_request(service = %{"auth" => true}, conn) do
    # Get authorization from request header (returns a list):
    tokens = get_req_header(conn, "authorization")
    case any_token_valid?(tokens) do
      true -> forward_request(service, conn)
      false -> send_resp(conn, 401, encode_error_message("Missing or invalid token"))
    end
  end
  # Authentication not required
  @spec check_and_forward_request(route_map, %Plug.Conn{}) :: %Plug.Conn{}
  defp check_and_forward_request(service = %{"auth" => false}, conn) do
    forward_request(service, conn)
  end

  @spec any_token_valid?([]) :: false
  defp any_token_valid?([]), do: false
  @spec any_token_valid?([String.t, ...]) :: boolean
  defp any_token_valid?(tokens) do
    tokens |> Enum.any?(&Jwt.valid?/1)
  end

  @spec forward_request(route_map, %Plug.Conn{}) :: %Plug.Conn{}
  defp forward_request(service, conn) do
    log_to_kafka(service, conn)
    %{
      method: method,
      request_path: request_path,
      params: params,
      req_headers: req_headers
    } = conn
    # Build URL
    url = build_url(service, request_path)
    # Match URL against HTTP method to forward it to specific service
    res =
      case method do
        "GET" -> Base.get!(attachQueryParams(url, params), req_headers)
        "POST" -> Base.post!(url, Poison.encode!(params), req_headers)
        "PUT" -> Base.put!(url, Poison.encode!(params), req_headers)
        "DELETE" -> Base.delete!(url, req_headers)
        _ -> nil
      end
    send_response({:ok, conn, res})
  end

  @spec log_to_kafka(route_map, %Plug.Conn{}) :: :ok
  defp log_to_kafka(%{"auth" => true} = service, conn) do
    Kafka.log_proxy_api_call(service, conn)
  end
  defp log_to_kafka(_service, _conn) do
    # no-op - we only log authenticated requests for now.
    :ok
  end

  # Builds URL where REST request should be proxied
  @spec build_url(route_map, String.t) :: String.t
  defp build_url(service, request_path) do
    host = System.get_env(service["host"]) || "localhost"
    "#{host}:#{service["port"]}#{request_path}"
  end

  # Workaround for HTTPoison/URI.encode not supporting nested query params
  @spec attachQueryParams(String.t, nil) :: String.t
  defp attachQueryParams(url, nil), do: url

  @spec attachQueryParams(String.t, map) :: String.t
  defp attachQueryParams(url, params) do
    url <> "?" <> Query.encode(params)
  end

  # Function for sending response back to client
  @spec send_response({:ok, %Plug.Conn{}, nil}) :: %Plug.Conn{}
  defp send_response({:ok, conn, nil}) do
    send_resp(conn, 405, encode_error_message("Method is not supported"))
  end

  @spec send_response({:ok, %Plug.Conn{}, map}) :: %Plug.Conn{}
  defp send_response({:ok, conn, %{headers: headers, status_code: status_code, body: body}}) do
    %{conn | resp_headers: headers} |> send_resp(status_code, body)
  end
end