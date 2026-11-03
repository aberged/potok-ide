defmodule PotokIdeWeb.EmailComponents do
  @moduledoc """
  The look of Potok's emails: the landing page's blues, serif titles and pill
  button (see `.landing` in `app.css`), written as tables and inline styles,
  the only layout mail clients reliably keep.
  """
  use Phoenix.Component
  use Gettext, backend: PotokIdeWeb.Gettext
  use PotokIdeWeb, :verified_routes

  @doc """
  Turns a rendered email template into the HTML body.
  """
  def to_html(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  @doc """
  Joins the plain-text body from its paragraphs, skipping the missing ones.
  """
  def to_text(paragraphs) do
    footer = "Potok · " <> gettext("A social application platform") <> "\n" <> home_url()

    (Enum.reject(paragraphs, &(&1 in [nil, ""])) ++ ["--\n" <> footer])
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  @doc """
  The whole email document: the Potok mark above a white card on a pale sky
  background, with the platform's line and the recipient under it.
  """
  attr :to, :string, required: true, doc: "the recipient's address, named in the footer"
  attr :title, :string, required: true
  attr :eyebrow, :string, required: true
  attr :preheader, :string, required: true, doc: "the line inboxes show after the subject"
  slot :inner_block, required: true

  def layout(assigns) do
    assigns =
      assign(assigns,
        lang: Gettext.get_locale(PotokIdeWeb.Gettext),
        home_url: home_url(),
        mark_url: url(~p"/images/email/mark.png")
      )

    ~H"""
    <!DOCTYPE html>
    <html lang={@lang}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="x-apple-disable-message-reformatting" />
        <meta name="color-scheme" content="light" />
        <meta name="supported-color-schemes" content="light" />
        <title>{@title}</title>
        <style phx-no-curly-interpolation>
          body { margin: 0; padding: 0; -webkit-text-size-adjust: 100%; }
          a { color: #0a5bc4; }
          @media (max-width: 600px) {
            .potok-outer { padding: 24px 12px 32px !important; }
            .potok-card { padding: 28px 22px 24px !important; }
            .potok-title { font-size: 26px !important; line-height: 32px !important; }
          }
        </style>
      </head>
      <body style="margin:0;padding:0;background-color:#f3f8fc;">
        <div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;mso-hide:all;">
          {@preheader}
        </div>
        <table
          role="presentation"
          width="100%"
          cellpadding="0"
          cellspacing="0"
          border="0"
          bgcolor="#f3f8fc"
          style="background-color:#f3f8fc;"
        >
          <tr>
            <td class="potok-outer" align="center" style="padding:40px 16px 48px;">
              <table
                role="presentation"
                width="100%"
                cellpadding="0"
                cellspacing="0"
                border="0"
                style="max-width:520px;"
              >
                <tr>
                  <td align="center" style="padding:0 0 22px;">
                    <a href={@home_url} style="text-decoration:none;color:#0b1b2b;">
                      <img
                        src={@mark_url}
                        width="34"
                        height="34"
                        alt=""
                        style="display:inline-block;vertical-align:middle;border:0;"
                      />
                      <span style={"display:inline-block;vertical-align:middle;margin-left:8px;font-family:#{serif()};font-size:23px;font-weight:600;letter-spacing:-0.01em;color:#0b1b2b;"}>
                        Potok
                      </span>
                    </a>
                  </td>
                </tr>
                <tr>
                  <td
                    class="potok-card"
                    bgcolor="#ffffff"
                    style={"background-color:#ffffff;border:1px solid #dbe9f5;border-radius:24px;padding:40px 40px 32px;text-align:left;font-family:#{sans()};font-size:16px;line-height:26px;color:#3d4a57;"}
                  >
                    <p style="margin:0 0 10px;font-size:12px;line-height:16px;font-weight:700;letter-spacing:0.14em;text-transform:uppercase;color:#0a5bc4;">
                      {@eyebrow}
                    </p>
                    <h1
                      class="potok-title"
                      style={"margin:0 0 20px;font-family:#{serif()};font-size:30px;line-height:36px;font-weight:600;letter-spacing:-0.015em;color:#0b1b2b;"}
                    >
                      {@title}
                    </h1>
                    {render_slot(@inner_block)}
                  </td>
                </tr>
                <tr>
                  <td
                    align="center"
                    style={"padding:24px 12px 0;font-family:#{sans()};font-size:13px;line-height:20px;color:#7a8794;"}
                  >
                    <p style="margin:0;">
                      <a
                        href={@home_url}
                        style="color:#7a8794;font-weight:600;text-decoration:none;"
                      >potok</a>{" · " <> gettext("A social application platform")}
                    </p>
                    <p style="margin:4px 0 0;">
                      {gettext("Sent to %{email}.", email: @to)}
                    </p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  @doc """
  A paragraph of the card's body text.
  """
  slot :inner_block, required: true

  def paragraph(assigns) do
    ~H"""
    <p style="margin:0 0 14px;">{render_slot(@inner_block)}</p>
    """
  end

  @doc """
  The email's one action, the landing page's gradient pill. Clients without
  gradients show the solid blue under it.
  """
  attr :href, :string, required: true
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:26px 0 14px;">
      <tr>
        <td
          align="center"
          bgcolor="#0a5bc4"
          style="border-radius:9999px;background-color:#0a5bc4;background-image:linear-gradient(135deg,#2e8fde,#0056c4);"
        >
          <a
            href={@href}
            target="_blank"
            style={"display:inline-block;padding:14px 28px;border-radius:9999px;font-family:#{sans()};font-size:16px;line-height:20px;font-weight:600;color:#ffffff;text-decoration:none;"}
          >
            {render_slot(@inner_block)}&nbsp;&rarr;
          </a>
        </td>
      </tr>
    </table>
    """
  end

  @doc """
  Small grey text, for how long a link works and what to do if the email
  was unexpected.
  """
  slot :inner_block, required: true

  def note(assigns) do
    ~H"""
    <p style="margin:0 0 10px;font-size:14px;line-height:22px;color:#6b7785;">
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  The bottom of the card, under a thin line: the Android app's link when
  there is one, and the address to copy for when the button doesn't work.
  """
  attr :url, :string, required: true
  attr :app_url, :string, default: nil

  def fallback(assigns) do
    ~H"""
    <div style="margin:26px 0 0;padding:22px 0 0;border-top:1px solid #e6eef6;font-size:13px;line-height:20px;color:#7a8794;">
      <p :if={@app_url} style="margin:0 0 12px;">
        {gettext("Using the Potok Android app?")}
        <a href={@app_url} target="_blank" style="color:#0a5bc4;font-weight:600;">
          {gettext("Open this link in the app")}
        </a>
      </p>
      <p style="margin:0 0 6px;">
        {gettext("If the button doesn't work, copy this address into your browser:")}
      </p>
      <p style="margin:0;padding:10px 12px;border-radius:12px;background-color:#f3f8fc;word-break:break-all;">
        <a href={@url} target="_blank" style="color:#0a5bc4;text-decoration:none;">{@url}</a>
      </p>
    </div>
    """
  end

  @doc """
  The plain-text line of `fallback/1`'s app link. Text has no button, so the
  link it stands for is already written out.
  """
  def app_link_text(nil), do: nil

  def app_link_text(app_url) do
    gettext("Using the Potok Android app?") <>
      " " <> gettext("Open this link in the app") <> ":\n" <> app_url
  end

  @doc """
  Splits a translated sentence around the `%{link}` it was given as
  `link_marker/0`, so the link can be rendered inside it.
  """
  def link_marker, do: "\u0000link\u0000"

  def split_at_link(sentence) do
    case String.split(sentence, link_marker(), parts: 2) do
      [before, rest] -> {before, rest}
      [sentence] -> {sentence, ""}
    end
  end

  def home_url, do: url(~p"/")

  defp serif, do: "'Iowan Old Style','Palatino Linotype',Palatino,Charter,Georgia,serif"

  defp sans,
    do:
      "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Helvetica,Arial,sans-serif"
end
