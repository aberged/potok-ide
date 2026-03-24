defmodule PotokIdeWeb.PushSubscriptionController do
  use PotokIdeWeb, :controller

  alias PotokIde.Accounts

  def create(conn, %{"subscription" => subscription_params}) do
    with {:ok, attrs} <- normalize_subscription_params(subscription_params, user_agent(conn)),
         {:ok, subscription} <-
           Accounts.upsert_push_subscription(conn.assigns.current_scope.account, attrs) do
      json(conn, %{enabled: true, endpoint: subscription.endpoint})
    else
      {:error, :invalid_subscription} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid push subscription payload."})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing push subscription payload."})
  end

  def delete(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) and endpoint != "" do
    :ok = Accounts.delete_push_subscription(conn.assigns.current_scope.account, endpoint)
    json(conn, %{enabled: false})
  end

  def delete(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing push subscription endpoint."})
  end

  def test(conn, params) do
    account = conn.assigns.current_scope.account
    endpoint = Map.get(params, "endpoint")

    case Accounts.send_test_push_notification(account, endpoint) do
      {:ok, _endpoint} ->
        json(conn, %{sent: true})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No saved push subscription was found for this account."})

      {:error, :expired} ->
        conn
        |> put_status(:gone)
        |> json(%{error: "The saved push subscription expired and has been removed."})

      {:error, :not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Push notifications are not configured on this server."})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: format_error(reason)})
    end
  end

  defp normalize_subscription_params(
         %{
           "endpoint" => endpoint,
           "keys" => %{"auth" => auth, "p256dh" => p256dh}
         } = params,
         user_agent
       )
       when is_binary(endpoint) and is_binary(auth) and is_binary(p256dh) do
    {:ok,
     %{
       endpoint: endpoint,
       auth: auth,
       p256dh: p256dh,
       expires_at: parse_expiration_time(Map.get(params, "expirationTime")),
       user_agent: user_agent
     }}
  end

  defp normalize_subscription_params(_params, _user_agent), do: {:error, :invalid_subscription}

  defp parse_expiration_time(nil), do: nil

  defp parse_expiration_time(value) when is_float(value), do: parse_expiration_time(round(value))

  defp parse_expiration_time(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  defp parse_expiration_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> parse_expiration_time(integer)
      _ -> nil
    end
  end

  defp parse_expiration_time(_value), do: nil

  defp user_agent(conn) do
    conn
    |> get_req_header("user-agent")
    |> List.first()
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%\{(\w+)\}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_error({type, detail}), do: "#{type}: #{detail}"
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
