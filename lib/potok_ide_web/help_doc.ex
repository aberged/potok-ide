defmodule PotokIdeWeb.HelpDoc do
  @moduledoc """
  The help page (`/pomoc`) and its tutorials (`/pomoc/<slug>`) in each
  language, read at compile time.

  `priv/static/HELP.sr.md` is the reference: edit it, then run
  `mix potok.sr_cyrl` for `HELP.sr_Cyrl.md`. `HELP.en.md` follows the Serbian
  text by hand. Each tutorial walks through one of the help page's example
  organizations and lives in `priv/static/help/<slug>.<locale>.md`, under the
  same rules. The pictures come from `help_shots/` (see its README), which
  writes them with their sizes in `priv/static/images/help/manifest.json`.
  `PotokIdeWeb.HelpMarkdown` says what the texts may hold.
  """

  alias PotokIdeWeb.HelpMarkdown

  @static Path.expand("../../priv/static", __DIR__)
  @files %{"sr" => "HELP.sr.md", "sr_Cyrl" => "HELP.sr_Cyrl.md", "en" => "HELP.en.md"}
  @manifest_path Path.join(@static, "images/help/manifest.json")

  # In the order of the help page's examples.
  @tutorials ~w(mesna-zajednica zadruga zgrada)

  @external_resource @manifest_path
  for {_locale, file} <- @files, do: @external_resource(Path.join(@static, file))

  for slug <- @tutorials, {locale, _file} <- @files do
    @external_resource Path.join(@static, "help/#{slug}.#{locale}.md")
  end

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

  @tutorial_docs (for slug <- @tutorials,
                      {locale, _file} <- @files,
                      path = Path.join(@static, "help/#{slug}.#{locale}.md"),
                      File.exists?(path),
                      into: %{} do
                    {{slug, locale}, path |> File.read!() |> HelpMarkdown.parse(@manifest)}
                  end)

  @doc "The page in this locale, or in Serbian Latin when there is none."
  @spec get(String.t()) :: HelpMarkdown.t()
  def get(locale), do: Map.get(@docs, locale) || Map.fetch!(@docs, "sr")

  @doc "The locales that have a text of their own."
  def locales, do: @docs |> Map.keys() |> Enum.sort()

  @doc "Where each locale's text lives."
  def files, do: Map.new(@files, fn {locale, file} -> {locale, Path.join(@static, file)} end)

  @doc "The tutorials' slugs, in the order of the help page's examples."
  def tutorial_slugs, do: @tutorials

  @doc "A tutorial in this locale, or in Serbian Latin when there is none."
  @spec tutorial(String.t(), String.t()) :: {:ok, HelpMarkdown.t()} | :error
  def tutorial(slug, locale) when slug in @tutorials do
    {:ok, Map.get(@tutorial_docs, {slug, locale}) || Map.fetch!(@tutorial_docs, {slug, "sr"})}
  end

  def tutorial(_slug, _locale), do: :error

  @doc "The locales in which this tutorial has a text of its own."
  def tutorial_locales(slug) do
    for {{^slug, locale}, _doc} <- @tutorial_docs, do: locale
  end

  @doc "Every tutorial's slug, title and lead in this locale, for links to them."
  def tutorials(locale) do
    for slug <- @tutorials do
      {:ok, doc} = tutorial(slug, locale)
      %{slug: slug, title: doc.title, lead: doc.lead}
    end
  end

  @doc "Every page in Serbian Latin: the help page and each tutorial."
  def all_pages do
    [get("sr") | Enum.map(@tutorials, fn slug -> elem(tutorial(slug, "sr"), 1) end)]
  end

  @doc "The pictures' sizes, as `help_shots/` wrote them."
  def manifest, do: @manifest

  @doc "Where the pictures live."
  def images_dir, do: Path.join(@static, "images/help")
end
