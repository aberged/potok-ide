defmodule Mix.Tasks.Potok.SrCyrl do
  @moduledoc """
  Generates the Cyrillic Serbian translations (`sr_Cyrl`) and privacy policy
  from the Latin ones (`sr`).

  `sr` is the reference: edit it, then run this task. The `sr_Cyrl` files are
  output, so changes made to them by hand are lost. A test fails when they are
  out of step.
  """
  use Mix.Task

  alias Expo.Message
  alias Expo.PO

  @shortdoc "Generates the sr_Cyrl translations from sr"

  @source "priv/gettext/sr/LC_MESSAGES"
  @target "priv/gettext/sr_Cyrl/LC_MESSAGES"
  @policy_source "priv/static/PRIVACY_POLICY.sr.md"
  @policy_target "priv/static/PRIVACY_POLICY.sr_Cyrl.md"

  @letters ~w(a b c č ć d dž đ e f g h i j k l lj m n nj o p r s š t u v z ž)
           |> Enum.zip(~w(а б ц ч ћ д џ ђ е ф г х и ј к л љ м н њ о п р с ш т у в з ж))
           |> Enum.flat_map(fn {latin, cyrillic} ->
             capital = String.upcase(cyrillic)

             [
               {latin, cyrillic},
               {String.capitalize(latin), capital},
               {String.upcase(latin), capital}
             ]
           end)
           |> Map.new()

  # What stays in Latin: interpolations, markup and addresses, the role names
  # (users see and type them as they are), technical names and brands.
  @kept ~r/
    %?\{[^}]*\} | <[^>]*> | `[^`]*` | \b(?:https?|data):\S* | @?\b(?:admin|everyone)\b |
    \b(?:API|Apple|Auth|BEAM|CSS|daisyUI|Ecto|Elixir|Endpoint|English|ETS|ExUnit|FCM|
    Firebase\ Cloud\ Messaging|Firebase|Gmail|Google\ Play|Google|Heroicons|HTML|HTTPS|iPhone|
    JavaScript|LiveView|localhost|Markdown|Outlook|P256DH|Phoenix|PostgreSQL|Presence|PubSub|
    service\ worker|Tailwind|URL|User\ Agent|WebSocket)\b
  /ux

  # Foreign words that the Latin text keeps in their own spelling.
  @words %{
    "Chat" => "Чет",
    "chat" => "чет",
    "feed" => "фид",
    "Push" => "Пуш",
    "push" => "пуш",
    "emoji" => "емоџи"
  }

  @impl Mix.Task
  def run(_args) do
    File.mkdir_p!(@target)

    for {path, contents} <- generate() do
      File.write!(path, contents)
      Mix.shell().info("Wrote #{path}")
    end
  end

  @doc "Every `sr_Cyrl` file as `{path, contents}`, from the current `sr` files."
  def generate do
    translations =
      for source <- Path.wildcard("#{@source}/*.po") do
        messages = source |> PO.parse_file!() |> to_cyrillic()

        {Path.join(@target, Path.basename(source)),
         messages |> PO.compose() |> IO.iodata_to_binary()}
      end

    [{@policy_target, @policy_source |> File.read!() |> transliterate()} | translations]
  end

  @doc "Latin Serbian text in Cyrillic, without what has to stay in Latin."
  def transliterate(text) do
    @kept
    |> Regex.split(text, include_captures: true)
    |> Enum.chunk_every(2, 2, [""])
    |> Enum.map_join(fn [plain, kept] -> letters(plain) <> kept end)
  end

  defp to_cyrillic(%Expo.Messages{} = messages) do
    %{
      messages
      | headers:
          Enum.map(messages.headers, &String.replace(&1, "Language: sr\n", "Language: sr_Cyrl\n")),
        messages: Enum.map(messages.messages, &message/1)
    }
  end

  defp message(%Message.Singular{} = message) do
    %{message | msgstr: Enum.map(message.msgstr, &transliterate/1)}
  end

  defp message(%Message.Plural{} = message) do
    %{
      message
      | msgstr:
          Map.new(message.msgstr, fn {form, text} -> {form, Enum.map(text, &transliterate/1)} end)
    }
  end

  defp letters(text) do
    text
    |> String.replace(Map.keys(@words), &Map.fetch!(@words, &1))
    |> String.replace(~r/lj|nj|dž|./iu, &Map.get(@letters, &1, &1))
  end
end
