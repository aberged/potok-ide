defmodule PotokIde.PushNotifications.WebPush do
  @curve :prime256v1
  @curve_oid {1, 2, 840, 10045, 3, 1, 7}
  @auth_info "Content-Encoding: auth" <> <<0>>
  @max_payload_length 4078
  @one_buffer <<1>>

  def encrypt(message, subscription, padding_length \\ 0)

  def encrypt(message, _subscription, padding_length)
      when byte_size(message) + padding_length > @max_payload_length do
    raise ArgumentError,
          "Push payload is too large. The message is #{byte_size(message)} bytes with #{padding_length} bytes of padding."
  end

  def encrypt(message, subscription, padding_length) do
    :ok = validate_subscription(subscription)

    client_public_key = subscription.keys.p256dh |> Base.url_decode64!(padding: false)
    client_auth_token = subscription.keys.auth |> Base.url_decode64!(padding: false)

    :ok = validate_length(client_auth_token, 16, "Subscription auth token is invalid.")
    :ok = validate_length(client_public_key, 65, "Subscription public key is invalid.")

    salt = :crypto.strong_rand_bytes(16)
    {server_public_key, server_private_key} = :crypto.generate_key(:ecdh, @curve)
    shared_secret = :crypto.compute_key(:ecdh, client_public_key, server_private_key, @curve)
    prk = hkdf(client_auth_token, shared_secret, @auth_info, 32)
    context = create_context(client_public_key, server_public_key)
    content_encryption_key = hkdf(salt, prk, create_info("aesgcm", context), 16)
    nonce = hkdf(salt, prk, create_info("nonce", context), 12)

    %{
      ciphertext:
        encrypt_payload(make_padding(padding_length) <> message, content_encryption_key, nonce),
      salt: salt,
      server_public_key: server_public_key
    }
  end

  def vapid_headers(endpoint, subject, public_key, private_key, expiration \\ 12 * 3600) do
    jwt = sign_vapid_jwt(endpoint, subject, public_key, private_key, expiration)

    %{
      "Authorization" => "WebPush " <> jwt,
      "Crypto-Key" => "p256ecdsa=" <> public_key
    }
  end

  defp sign_vapid_jwt(endpoint, subject, public_key_b64, private_key_b64, expiration) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    header = base64url!(%{alg: "ES256", typ: "JWT"})

    payload =
      base64url!(%{
        aud: audience(endpoint),
        exp: now + expiration,
        sub: subject
      })

    signing_input = header <> "." <> payload
    public_key = Base.url_decode64!(public_key_b64, padding: false)
    private_key = Base.url_decode64!(private_key_b64, padding: false)

    der_signature =
      :public_key.sign(signing_input, :sha256, {
        :ECPrivateKey,
        1,
        private_key,
        {:namedCurve, @curve_oid},
        public_key,
        nil
      })

    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der_signature)
    signature = <<r::unsigned-big-integer-size(256), s::unsigned-big-integer-size(256)>>

    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp audience(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and scheme != "" and is_binary(host) and host != "" ->
        scheme <> "://" <> host

      _uri ->
        raise ArgumentError, "Subscription endpoint is invalid."
    end
  end

  defp audience(_endpoint) do
    raise ArgumentError, "Subscription endpoint is invalid."
  end

  defp base64url!(value) do
    value
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp hkdf(salt, input_key_material, info, length) do
    prk =
      :crypto.mac_init(:hmac, :sha256, salt)
      |> :crypto.mac_update(input_key_material)
      |> :crypto.mac_final()

    :crypto.mac_init(:hmac, :sha256, prk)
    |> :crypto.mac_update(info)
    |> :crypto.mac_update(@one_buffer)
    |> :crypto.mac_final()
    |> binary_part(0, length)
  end

  defp create_context(client_public_key, server_public_key) do
    <<0, byte_size(client_public_key)::unsigned-big-integer-size(16)>> <>
      client_public_key <>
      <<byte_size(server_public_key)::unsigned-big-integer-size(16)>> <>
      server_public_key
  end

  defp create_info(type, context) do
    "Content-Encoding: " <> type <> <<0>> <> "P-256" <> context
  end

  defp encrypt_payload(plaintext, content_encryption_key, nonce) do
    {cipher_text, cipher_tag} =
      :crypto.crypto_one_time_aead(
        :aes_128_gcm,
        content_encryption_key,
        nonce,
        plaintext,
        "",
        true
      )

    cipher_text <> cipher_tag
  end

  defp make_padding(padding_length) do
    <<padding_length::unsigned-big-integer-size(16)>> <> :binary.copy(<<0>>, padding_length)
  end

  defp validate_subscription(%{keys: %{p256dh: p256dh, auth: auth}, endpoint: endpoint})
       when is_binary(p256dh) and is_binary(auth) and is_binary(endpoint) do
    if valid_endpoint?(endpoint) do
      :ok
    else
      raise ArgumentError, "Subscription endpoint is invalid."
    end
  end

  defp validate_subscription(_subscription) do
    raise ArgumentError, "Subscription is missing required endpoint or key data."
  end

  defp valid_endpoint?(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and scheme != "" and is_binary(host) and host != "" ->
        true

      _uri ->
        false
    end
  end

  defp valid_endpoint?(_endpoint), do: false

  defp validate_length(bytes, expected_size, _message) when byte_size(bytes) == expected_size,
    do: :ok

  defp validate_length(_bytes, _expected_size, message), do: raise(ArgumentError, message)
end
