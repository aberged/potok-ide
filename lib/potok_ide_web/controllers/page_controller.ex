defmodule PotokIdeWeb.PageController do
  use PotokIdeWeb, :controller

  import PotokIdeWeb.AccountAuth, only: [assign_nav_counts: 2]

  alias PotokIde.DomainMap
  alias PotokIdeWeb.DomainCopy
  alias PotokIdeWeb.HelpDoc
  alias PotokIdeWeb.HelpGuides
  alias PotokIdeWeb.StackCopy

  plug :assign_nav_counts when action in [:privacy, :terms]

  # The privacy policy and the terms of use. `mix potok.sr_cyrl` writes the
  # Cyrillic texts from the Latin ones.
  for {page, files} <- %{
        privacy: %{
          "en" => "PRIVACY_POLICY.md",
          "sr" => "PRIVACY_POLICY.sr.md",
          "sr_Cyrl" => "PRIVACY_POLICY.sr_Cyrl.md"
        },
        terms: %{"en" => "TERMS.md", "sr" => "TERMS.sr.md", "sr_Cyrl" => "TERMS.sr_Cyrl.md"}
      },
      {locale, file} <- files do
    path = Path.expand("../../../priv/static/#{file}", __DIR__)
    @external_resource path

    html =
      path
      |> File.read!()
      |> String.trim()
      |> Earmark.as_html!(breaks: true)
      |> HtmlSanitizeEx.html5()

    defp legal_html(unquote(page), unquote(locale)), do: unquote(html)
  end

  # The overview of the apps the movement organized itself with, which Potok
  # grew out of. It is about Serbia and has only Serbian sources, so English
  # visitors read the Latin text too. Tables scroll inside a frame of their
  # own; the matrix (the one with the most columns) centers its marks.
  for {locale, file} <- %{"sr" => "ORIGIN.sr.md", "sr_Cyrl" => "ORIGIN.sr_Cyrl.md"} do
    path = Path.expand("../../../priv/static/#{file}", __DIR__)
    @external_resource path

    html =
      path
      |> File.read!()
      |> String.trim()
      # Unescaped for `<span lang=en>`, which keeps English titles in Latin.
      |> Earmark.as_html!(breaks: true, escape: false)
      |> HtmlSanitizeEx.html5()
      |> String.replace(~s( style="text-align: left;"), "")
      |> then(
        &Regex.replace(~r/<table>.*?<\/table>/s, &1, fn table ->
          columns = length(Regex.scan(~r/<th>/, table))
          class = if columns > 5, do: "or-table or-matrix", else: "or-table"
          ~s(<div class="#{class}">#{table}</div>)
        end)
      )
      # Fonts draw ● much smaller than ○, and — reads as a mark of its own.
      |> then(
        &Regex.replace(~r/<td>\s*(—|●)\s*<\/td>/u, &1, fn _, mark ->
          class = if mark == "●", do: "or-full", else: "or-none"
          ~s(<td class="#{class}">#{mark}</td>)
        end)
      )
      |> String.replace(
        ~s(<a href="http),
        ~s(<a target="_blank" rel="noopener noreferrer" href="http)
      )

    defp origin_html(unquote(locale)), do: unquote(html)
  end

  defp origin_html(_locale), do: origin_html("sr")

  def home(conn, _params) do
    current_account =
      case conn.assigns[:current_scope] do
        %{account: account} -> account
        _ -> nil
      end

    cond do
      conn.assigns.current_profile ->
        redirect(conn, to: ~p"/groups")

      current_account ->
        redirect(conn, to: ~p"/profiles")

      true ->
        render(conn, :home)
    end
  end

  def domain(conn, _params) do
    conn
    |> assign(:page_title, DomainCopy.title())
    |> assign(:page_description, DomainCopy.lead())
    |> render(:domain, map: DomainCopy.map(DomainMap.graph()))
  end

  def stack(conn, _params) do
    conn
    |> assign(:page_title, StackCopy.title())
    |> assign(:page_description, StackCopy.lead())
    |> render(:stack, tools: StackCopy.tools())
  end

  def origin(conn, _params) do
    locale = conn.assigns.current_locale

    conn
    |> assign(:page_title, gettext("Where Potok springs from"))
    |> assign(:page_description, PotokIdeWeb.PageHTML.origin_lead())
    |> render(:origin, origin_html: origin_html(locale), serbian_only?: locale == "en")
  end

  def help(conn, _params) do
    locale = conn.assigns.current_locale
    doc = HelpDoc.get(locale)

    conn
    |> assign(:page_title, gettext("Help"))
    |> assign(:page_description, doc.lead)
    |> render(:help, doc: doc, serbian_pictures?: locale == "en")
  end

  # For those who type the address in English; anchors stay in the browser.
  def help_redirect(conn, _params), do: redirect(conn, to: ~p"/pomoc")

  # A page under the help: one on how Potok works inside (`HelpGuides`), or
  # one of the help page's example organizations, built step by step.
  def help_tutorial(conn, %{"slug" => slug}) do
    locale = conn.assigns.current_locale

    case {HelpGuides.guide(slug), HelpDoc.tutorial(slug, locale)} do
      {{:ok, guide}, _no_tutorial} ->
        conn
        |> assign(:page_title, guide.title)
        |> assign(:page_description, HelpGuides.plain(guide.lead))
        |> render(
          guide.template,
          [guide: guide, f: HelpGuides.facts()] ++ guide_assigns(guide.template)
        )

      {:error, {:ok, doc}} ->
        conn
        |> assign(:page_title, doc.title)
        |> assign(:page_description, doc.lead)
        |> render(:help_tutorial,
          doc: doc,
          others: Enum.reject(HelpDoc.tutorials(locale), &(&1.slug == slug)),
          serbian_pictures?: locale == "en"
        )

      {:error, :error} ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: PotokIdeWeb.Router
    end
  end

  # What each of those pages shows that it reads from the code.
  defp guide_assigns(:help_processes_apps), do: [steps: HelpGuides.step_names()]

  defp guide_assigns(:help_app_architecture),
    do: [api: HelpGuides.api(), limits: HelpGuides.limits()]

  defp guide_assigns(:help_access), do: [calc: HelpGuides.calc()]

  def help_tutorial_redirect(conn, %{"slug" => slug}),
    do: redirect(conn, to: ~p"/pomoc/#{slug}")

  def privacy(conn, _params) do
    render(conn, :privacy, privacy_policy_html: legal_html(:privacy, conn.assigns.current_locale))
  end

  def terms(conn, _params) do
    render(conn, :terms, terms_html: legal_html(:terms, conn.assigns.current_locale))
  end
end
