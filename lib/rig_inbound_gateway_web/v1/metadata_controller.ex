defmodule RigInboundGatewayWeb.V1.MetadataController do
  @moduledoc """
  Handles inbound metadata sets and the indexing and distribution of metadata
  """
  use RigInboundGatewayWeb, :controller
  use Rig.Config, [:jwt_fields, :indexed_metadata]

  alias Result
  alias RIG.JWT
  alias RIG.Plug.BodyReader

  require Logger

  @doc """
  Sets metadata KV pairs for an existing connection, replacing previous metadata sets.

  There may be indexed metadata pairs defined. If a metadata set does not contain these indexed keys, it cannot be accepted.

  ## Example

  Metadata set that contains a user ID, locale and timezone:

      {
        "metadata": {
          "userid": "9ab1bff2-a8d8-455c-b48a-50145d7d8e30",
          "locale": "de-AT",
          "timezone": "GMT+1"
        }
      }

  In this example, the field "userid" might be indexed. In this case, the connection token would get associated with the value of the "userid" field (it will be possible to automatically take the user id from the JWT token (so that it cannot be changed by any other way) and index that; this will be serverside configuration).
  In addition to that, the value of the "userid", "locale" and "timezone" fields would get associated to the connection token.

  To sum it up: the connection token is indexed by default, while all other fields can be indexed by configuration.

  So the association would look like so:

      userid -> connection token

      conection token ->
        userid
        locale
        timezone

  All indexed fields are then being propagated to all other instances, so they know where to find the corresponding metadata.

  ## Example

  A user connects to RIG 1 and sends the metadata fields from above to RIG 1. RIG 1 would propagate the connection token and the userid along with the RIG instance ID to all other RIG instances.
  If someone were to access the metadata of a user from RIG 3, RIG 3 would know where to find the metadata, ask RIG 1 for it and return the metadata set.

  ## Dirty testing with JWT

      AUTH='Authorization:Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI5YWIxYmZmMi1hOGQ4LTQ1NWMtYjQ4YS01MDE0NWQ3ZDhlMzAiLCJuYW1lIjoiSm9obiBEb2UiLCJpYXQiOjE1Njg3MTMzNjEsImV4cCI6NDEwMzI1ODE0M30.kjiR7kFyOEeMJaY1zPCctut39eEWmKswUCNZdK5Q3-w'
      META='{ "metadata": { "locale": "de-AT", "timezone": "GMT+2" } }'
      http put ":4000/_rig/v1/connection/sse/${CONN_TOKEN}/metadata" <<< "$META" "$AUTH"

  ## Dirty testing without JWT
      META='{ "metadata": { "userid": "9ab1bff2-a8d8-455c-b48a-50145d7d8e30", "locale": "de-AT", "timezone": "GMT+2" } }'
      http put ":4000/_rig/v1/connection/sse/${CONN_TOKEN}/metadata" <<< "$META"

  """
  @spec set_metadata(conn :: Plug.Conn.t(), params :: map) :: Plug.Conn.t()
  def set_metadata(
        %{method: "PUT"} = conn,
        %{
          "connection_id" => connection_id
        }
      ) do

    conn
    |> accept_only_req_for(["application/json"])
    |> decode_metadata()
    |> do_set_metadata(connection_id)
  end

  defp decode_metadata(conn) do
    with {"application", "json"} <- content_type(conn),
         {:ok, body, conn} <- BodyReader.read_full_body(conn),
         {:ok, json} <- Jason.decode(body),
         {:parse, %{"metadata" => metadata}} <- {:parse, json} do

      conf = config()
      jwt_fields = conf.jwt_fields

      with {:ok, auth_tokens} <- Map.get(conn.assigns, :auth_tokens, [])
      |> Enum.map(fn
        {"bearer", token} -> JWT.parse_token(token)
        _ -> {:ok, %{}}
      end)
      |> Result.list_to_result()
      |> Result.map_err(fn decode_errors -> {:error, decode_errors} end) do

        # Merge the list of maps into a single map
        auth_tokens = Enum.reduce(auth_tokens, fn x, y ->
          Map.merge(x, y, fn _k, v1, v2 -> v2 ++ v1 end)
        end)

        # Get values from JWT
        jwt_vals = jwt_fields
        |> Enum.map(fn x ->
          key = x |> elem(0)
          jwt_key = x |> elem(1)
          {key, auth_tokens[jwt_key]}
        end)
        |> Enum.into(%{})

        # Merge values from metadata with the values from JWT, prioritizing JWT values
        metadata = Map.merge(metadata, jwt_vals)

        conn
        |> Plug.Conn.assign(:metadata, metadata)
      else
        {:error, _} ->
          conn
          |> Plug.Conn.assign(:metadata, metadata)
      end
    else
      {:parse, json} ->
        message = """
        Expected field "metadata" is not present.

        Decoded request body:
        #{inspect(json)}
        """

        fail!(conn, message)

      error ->
        message = """
        Expected JSON encoded body.

        Technical info:
        #{inspect(error)}
        """

        fail!(conn, message)
    end
  end

  defp do_set_metadata(%{halted: true} = conn, _connection_id), do: conn

  defp do_set_metadata(%{assigns: %{metadata: metadata}} = conn, connection_id) do
    # Check if metadata contains all the indexed fields; if not: send back a bad request
    # This needs to be done here because now the values from the JWT got inserted
    if contains_idx?(metadata) === false do
      message = """
        Metadata doesn't contain indexed fields.
        """

      fail!(conn, message)
    else
      Logger.info("Metadata: " <> inspect(metadata))

      conf = config()

      indexed_fields =
        Enum.map(conf.indexed_metadata, fn x ->
          {x, metadata[x]}
        end)

      Logger.info("Indexed fields: " <> inspect(indexed_fields))

      send_resp(conn, :no_content, "")
    end
  end

  defp contains_idx?(metadata) do
    conf = config()
    metadata_keys = Enum.map(metadata, fn x -> x |> elem(0) end)
    Enum.all?(conf.indexed_metadata, fn x -> Enum.member?(metadata_keys, x) end)
  end

  defp fail!(conn, msg) do
    send_resp(conn, :bad_request, msg)
    Plug.Conn.halt(conn)
  end
end
