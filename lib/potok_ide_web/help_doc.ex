defmodule PotokIdeWeb.HelpDoc do
  @moduledoc """
  The help page (`/pomoc`) in each language, read at compile time.

  `priv/static/HELP.sr.md` is the reference: edit it, then run
  `mix potok.sr_cyrl` for `HELP.sr_Cyrl.md`. `HELP.en.md` follows the Serbian
  text by hand. The pictures come from `help_shots/` (see its README), which
  writes them with their sizes in `priv/static/images/help/manifest.json`.
  `PotokIdeWeb.HelpMarkdown` says what the text may hold.
  """

  alias PotokIdeWeb.HelpMarkdown

  @static Path.expand("../../priv/static", __DIR__)
  @files %{"sr" => "HELP.sr.md", "sr_Cyrl" => "HELP.sr_Cyrl.md", "en" => "HELP.en.md"}
  @manifest_path Path.join(@static, "images/help/manifest.json")

  @external_resource @manifest_path
  for {_locale, file} <- @files, do: @external_resource(Path.join(@static, file))

  @manifest (if File.exists?(@manifest_path) do
               @manifest_path |> File.read!() |> Jason.decode!()
             else
               %{}
             end)

  # A file that is not there yet (the Cyrillic one before the first
  # `mix potok.sr_cyrl`) falls back to Serbian Latin.
  @docs (for {locale, file} <- @files,
             path = Path.join(@static, file),
             File.exists?(path),
             into: %{} do
           {locale, path |> File.read!() |> HelpMarkdown.parse(@manifest)}
         end)

  @doc "The page in this locale, or in Serbian Latin when there is none."
  @spec get(String.t()) :: HelpMarkdown.t()
  def get(locale), do: Map.get(@docs, locale) || Map.fetch!(@docs, "sr")

  @doc "The locales that have a text of their own."
  def locales, do: @docs |> Map.keys() |> Enum.sort()

  @doc "Where each locale's text lives."
  def files, do: Map.new(@files, fn {locale, file} -> {locale, Path.join(@static, file)} end)

  @doc "The pictures' sizes, as `help_shots/` wrote them."
  def manifest, do: @manifest

  @doc "Where the pictures live."
  def images_dir, do: Path.join(@static, "images/help")
end
