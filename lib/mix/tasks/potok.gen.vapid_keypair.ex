defmodule Mix.Tasks.Potok.Gen.VapidKeypair do
  use Mix.Task

  @shortdoc "Generates a VAPID keypair for Potok web push notifications"

  @impl Mix.Task
  def run(_args) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    Mix.shell().info("WEB_PUSH_VAPID_PUBLIC_KEY=#{Base.url_encode64(public_key, padding: false)}")

    Mix.shell().info(
      "WEB_PUSH_VAPID_PRIVATE_KEY=#{Base.url_encode64(private_key, padding: false)}"
    )

    Mix.shell().info("WEB_PUSH_VAPID_SUBJECT=mailto:you@example.com")
  end
end
