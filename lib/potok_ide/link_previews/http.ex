defmodule PotokIde.LinkPreviews.HTTP do
  @moduledoc """
  Fetches the HTML of a page that a member linked, for its link preview.

  The URLs come from members, so every request, redirects included, must go
  to a public address on port 80 or 443. The host is resolved first and
  refused when any of its addresses is private; the connection is then made
  to the checked address (`Mint` with `hostname:` for SNI, the `Host` header
  and the certificate check), so DNS rebinding cannot swap in another one.
  Req's own adapter cannot pin the address without starting a Finch pool
  per host.

  Reading stops at `</head>`, where the tags a preview needs end, or at
  1 MB (YouTube's come after about 800 kB of scripts). Only `200` HTML
  responses count.

  Tests plug in `Req.Test` through the `:req_options` config (it replaces the
  adapter) and a `:resolver` that needs no network.
  """

  import Bitwise

  @max_redirects 3
  @max_body_bytes 1_000_000
  @connect_timeout 3_000
  @receive_timeout 5_000
  @html_types ~w(text/html application/xhtml+xml)

  @doc "`{:ok, html, final_url}` for a public HTML page, `:error` otherwise."
  def get_html(url) when is_binary(url), do: get_html(url, @max_redirects)

  defp get_html(url, redirects_left) do
    with {:ok, uri} <- parse_url(url),
         {:ok, address} <- resolve_public(uri.host),
         {:ok, response} <- request(uri, address) do
      handle_response(response, uri, redirects_left)
    else
      _ -> :error
    end
  end

  defp parse_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and port in [80, 443] ->
        {:ok, uri}

      _ ->
        :error
    end
  end

  # IPv4 first: it works from every machine, IPv6 egress does not.
  defp resolve_public(host) do
    with {:ok, [_ | _] = addresses} <- resolve(host),
         true <- Enum.all?(addresses, &public_address?/1) do
      {:ok, Enum.find(addresses, &(tuple_size(&1) == 4)) || hd(addresses)}
    else
      _ -> :error
    end
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} -> {:ok, [address]}
      {:error, _} -> config(:resolver, &dns_lookup/1).(host)
    end
  end

  @doc false
  def dns_lookup(host) do
    charlist = String.to_charlist(host)

    addresses =
      for family <- [:inet, :inet6],
          {:ok, found} <- [:inet.getaddrs(charlist, family)],
          address <- found,
          do: address

    {:ok, addresses}
  end

  @doc """
  False for loopback, private, shared (CGNAT), link-local (cloud metadata),
  unique-local (Fly's private network), multicast and reserved addresses,
  including IPv4 addresses inside IPv6 ones.
  """
  def public_address?({a, b, c, _d}) do
    not (a in [0, 10, 127] or a >= 224 or
           (a == 100 and b in 64..127) or
           (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or
           (a == 192 and b == 168) or
           (a == 192 and b == 0 and c in [0, 2]) or
           (a == 198 and b in 18..19))
  end

  # IPv4-mapped (`::ffff:a.b.c.d`) and NAT64 (`64:ff9b::a.b.c.d`) addresses.
  def public_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: public_address?(ipv4(high, low))
  def public_address?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: public_address?(ipv4(high, low))
  # Unspecified, loopback and the deprecated IPv4-compatible range.
  def public_address?({0, 0, 0, 0, 0, 0, _, _}), do: false

  def public_address?({first, _, _, _, _, _, _, _}) do
    not ((first &&& 0xFE00) == 0xFC00 or (first &&& 0xFFC0) == 0xFE80 or
           (first &&& 0xFFC0) == 0xFEC0 or (first &&& 0xFF00) == 0xFF00)
  end

  def public_address?(_address), do: false

  defp ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp request(uri, address) do
    [
      method: :get,
      url: uri,
      headers: request_headers(),
      redirect: false,
      retry: false,
      compressed: false,
      raw: true,
      adapter: &mint_adapter(&1, address)
    ]
    |> Req.new()
    |> Req.merge(config(:req_options, []))
    |> Req.request()
  end

  defp request_headers do
    [
      {"user-agent", "Mozilla/5.0 (compatible; PotokBot/1.0; +#{PotokIdeWeb.Endpoint.url()})"},
      {"accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"},
      {"accept-language", "#{PotokIdeWeb.Locale.default_locale()},en;q=0.8"},
      {"accept-encoding", "identity"}
    ]
  end

  defp handle_response(%Req.Response{status: status} = response, uri, redirects_left)
       when status in [301, 302, 303, 307, 308] do
    case Req.Response.get_header(response, "location") do
      [location | _] when redirects_left > 0 ->
        uri |> URI.merge(location) |> URI.to_string() |> get_html(redirects_left - 1)

      _ ->
        :error
    end
  end

  defp handle_response(%Req.Response{status: 200, body: body} = response, uri, _redirects_left)
       when is_binary(body) do
    if html?(response) do
      {:ok, binary_part(body, 0, min(byte_size(body), @max_body_bytes)), URI.to_string(uri)}
    else
      :error
    end
  end

  defp handle_response(_response, _uri, _redirects_left), do: :error

  defp html?(response) do
    case Req.Response.get_header(response, "content-type") do
      [type | _] ->
        media_type = type |> String.split(";", parts: 2) |> hd() |> String.trim()
        String.downcase(media_type) in @html_types

      [] ->
        false
    end
  end

  # One request on its own connection to the checked address, read until it
  # is done, the head is over, the body passes the limit or time runs out.
  defp mint_adapter(%Req.Request{url: uri} = request, address) do
    scheme = if uri.scheme == "https", do: :https, else: :http
    target = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    headers = for {name, values} <- request.headers, value <- values, do: {name, value}
    deadline = System.monotonic_time(:millisecond) + @receive_timeout

    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, address, uri.port,
             hostname: uri.host,
             mode: :passive,
             protocols: [:http1],
             transport_opts: [timeout: @connect_timeout]
           ),
         {:ok, conn, ref} <- request_on(conn, target, headers) do
      result =
        receive_response(conn, ref, deadline, %{status: nil, headers: [], body: [], size: 0})

      Mint.HTTP.close(conn)

      case result do
        {:ok, response} -> {request, response}
        {:error, error} -> {request, error}
      end
    else
      {:error, error} -> {request, error}
    end
  end

  defp request_on(conn, target, headers) do
    case Mint.HTTP.request(conn, "GET", target, headers, nil) do
      {:ok, conn, ref} ->
        {:ok, conn, ref}

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        {:error, error}
    end
  end

  defp receive_response(conn, ref, deadline, acc) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        case Enum.reduce_while(responses, {:cont, acc}, &collect(&1, &2, ref)) do
          {:cont, acc} -> receive_response(conn, ref, deadline, acc)
          {:done, acc} -> {:ok, to_response(acc)}
          {:error, error} -> {:error, error}
        end

      {:error, _conn, error, _responses} ->
        {:error, error}
    end
  end

  defp collect({:status, ref, status}, {:cont, acc}, ref),
    do: {:cont, {:cont, %{acc | status: status}}}

  defp collect({:headers, ref, headers}, {:cont, acc}, ref),
    do: {:cont, {:cont, %{acc | headers: acc.headers ++ headers}}}

  defp collect({:data, ref, data}, {:cont, acc}, ref) do
    acc = %{acc | body: [acc.body, data], size: acc.size + byte_size(data)}

    if acc.size >= @max_body_bytes or :binary.match(data, ["</head>", "</HEAD>"]) != :nomatch,
      do: {:halt, {:done, acc}},
      else: {:cont, {:cont, acc}}
  end

  defp collect({:done, ref}, {:cont, acc}, ref), do: {:halt, {:done, acc}}
  defp collect({:error, ref, error}, _result, ref), do: {:halt, {:error, error}}
  defp collect(_response, result, _ref), do: {:cont, result}

  defp to_response(acc) do
    Req.Response.new(
      status: acc.status,
      headers: acc.headers,
      body: IO.iodata_to_binary(acc.body)
    )
  end

  defp config(key, default) do
    :potok_ide
    |> Application.get_env(PotokIde.LinkPreviews, [])
    |> Keyword.get(key, default)
  end
end
