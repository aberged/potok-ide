defmodule PotokIdeWeb.ClientIp do
  @moduledoc """
  Puts the client's IP in `conn.remote_ip` when a proxy in front of the app
  names it in a header. On Fly that is `Fly-Client-IP`, which Fly's proxy sets;
  without it `remote_ip` is the proxy's own address.

  The header comes from `config :potok_ide, :client_ip_header`, set only where
  such a proxy stands. Anywhere else a client could send the header itself, so
  it is not read.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  # Read on every call: the endpoint's plugs are initialized at compile time,
  # before `config/runtime.exs`.
  @impl true
  def call(conn, opts) do
    header = Keyword.get_lazy(opts, :header, fn -> client_ip_header() end)

    with header when is_binary(header) <- header,
         [value | _] <- Plug.Conn.get_req_header(conn, header),
         {:ok, ip} <- value |> String.trim() |> :binary.bin_to_list() |> :inet.parse_address() do
      %{conn | remote_ip: ip}
    else
      _ -> conn
    end
  end

  defp client_ip_header, do: Application.get_env(:potok_ide, :client_ip_header)
end
