defmodule PotokIdeWeb.AccountEmails do
  @moduledoc """
  The emails about an account: the sign-in link, the invitation that opens a
  new account, and the confirmation of a new address. Each returns its subject
  with an HTML and a plain-text body, in the current Gettext locale.
  """
  use Phoenix.Component
  use Gettext, backend: PotokIdeWeb.Gettext
  use PotokIdeWeb, :verified_routes

  import PotokIdeWeb.EmailComponents

  alias PotokIde.Accounts.AccountToken

  @doc """
  The sign-in link of a confirmed account.
  """
  def sign_in(%{to: to, url: url} = params) do
    minutes = AccountToken.magic_link_validity_in_minutes()

    assigns = %{
      to: to,
      url: url,
      app_url: params[:app_url],
      eyebrow: gettext("Sign-in"),
      title: gettext("Here's your sign-in link"),
      lead: gettext("Press the button and you're in, no password needed."),
      action: gettext("Sign in to Potok"),
      validity:
        ngettext(
          "The link works for %{count} minute, and only once.",
          "The link works for %{count} minutes, and only once.",
          minutes
        ),
      not_you:
        gettext(
          "If this wasn't you, just ignore this email: no one gets into your account without this link."
        )
    }

    %{
      subject: gettext("Your Potok sign-in link"),
      html: to_html(sign_in_html(assigns)),
      text:
        to_text([
          assigns.title,
          assigns.lead,
          assigns.action <> ":\n" <> url,
          assigns.validity,
          assigns.not_you,
          app_link_text(assigns.app_url)
        ])
    }
  end

  defp sign_in_html(assigns) do
    ~H"""
    <.layout to={@to} title={@title} eyebrow={@eyebrow} preheader={@validity}>
      <.paragraph>{@lead}</.paragraph>
      <.button href={@url}>{@action}</.button>
      <.note>{@validity}</.note>
      <.note>{@not_you}</.note>
      <.fallback url={@url} app_url={@app_url} />
    </.layout>
    """
  end

  @doc """
  The first link of an account someone opened for the recipient. Names the
  inviter's username and the group's name when they are known.
  """
  def invitation(%{to: to, url: url} = params) do
    inviter = params[:inviter]
    group = params[:group]
    days = AccountToken.invitation_validity_in_days()

    {subject, title} =
      cond do
        inviter && group ->
          title =
            gettext("@%{username} invites you to “%{group}” on Potok",
              username: inviter,
              group: group
            )

          {title, title}

        inviter ->
          title = gettext("@%{username} invites you to Potok", username: inviter)
          {title, title}

        true ->
          {gettext("Your invitation to Potok"), gettext("Potok is waiting for you")}
      end

    {expired_before, expired_after} =
      gettext("If it expires, enter %{email} on %{link} and a new one will arrive.",
        email: to,
        link: link_marker()
      )
      |> split_at_link()

    assigns = %{
      to: to,
      url: url,
      app_url: params[:app_url],
      eyebrow: gettext("Invitation"),
      title: title,
      preheader: gettext("Your account is ready, and you don't need a password."),
      about:
        gettext(
          "Potok is where groups talk, exchange values, decide and remember what they decided."
        ),
      account:
        gettext(
          "An account for %{email} is already set up. You don't need a password: the button takes you straight in.",
          email: to
        ),
      group_note:
        group &&
          gettext(
            "Once you create your profile, the invitation to “%{group}” will be waiting among your invitations.",
            group: group
          ),
      action: gettext("Accept the invitation"),
      validity:
        ngettext(
          "The link works for %{count} day, and only once.",
          "The link works for %{count} days, and only once.",
          days
        ),
      expired_before: expired_before,
      expired_after: expired_after,
      sign_in_url: url(~p"/accounts/log-in/magic-link"),
      sign_in_label: gettext("the sign-in page"),
      unexpected:
        gettext(
          "Not expecting this invitation? Just ignore this email: nothing happens until someone clicks the link."
        )
    }

    expired =
      expired_before <>
        assigns.sign_in_label <> " (" <> assigns.sign_in_url <> ")" <> expired_after

    %{
      subject: subject,
      html: to_html(invitation_html(assigns)),
      text:
        to_text([
          title,
          assigns.about,
          assigns.account,
          assigns.group_note,
          assigns.action <> ":\n" <> url,
          assigns.validity <> " " <> expired,
          assigns.unexpected,
          app_link_text(assigns.app_url)
        ])
    }
  end

  defp invitation_html(assigns) do
    ~H"""
    <.layout to={@to} title={@title} eyebrow={@eyebrow} preheader={@preheader}>
      <.paragraph>{@about}</.paragraph>
      <.paragraph>{@account}</.paragraph>
      <.paragraph :if={@group_note}>{@group_note}</.paragraph>
      <.button href={@url}>{@action}</.button>
      <.note>
        {@validity <> " " <> @expired_before}<a
          href={@sign_in_url}
          target="_blank"
          style="color:#0a5bc4;"
        >{@sign_in_label}</a>{@expired_after}
      </.note>
      <.note>{@unexpected}</.note>
      <.fallback url={@url} app_url={@app_url} />
    </.layout>
    """
  end

  @doc """
  The confirmation of a new address, sent to that address.
  """
  def email_change(%{to: to, old_email: old_email, url: url}) do
    days = AccountToken.change_email_validity_in_days()

    assigns = %{
      to: to,
      url: url,
      eyebrow: gettext("Address change"),
      title: gettext("Confirm your new address"),
      preheader: gettext("Until you confirm, your account keeps the old address."),
      lead:
        gettext(
          "A request came in to move your Potok account from %{old_email} to this address, %{new_email}.",
          old_email: old_email,
          new_email: to
        ),
      settings:
        gettext(
          "The link opens your account settings; if needed, Potok will ask you to sign in first."
        ),
      action: gettext("Confirm address"),
      validity:
        ngettext(
          "The link works for %{count} day, and only once.",
          "The link works for %{count} days, and only once.",
          days
        ),
      not_you:
        gettext(
          "If you don't know about this change, ignore this email: the account stays on the old address."
        )
    }

    %{
      subject: gettext("Confirm your new email address for Potok"),
      html: to_html(email_change_html(assigns)),
      text:
        to_text([
          assigns.title,
          assigns.lead,
          assigns.settings,
          assigns.action <> ":\n" <> url,
          assigns.validity,
          assigns.not_you
        ])
    }
  end

  defp email_change_html(assigns) do
    ~H"""
    <.layout to={@to} title={@title} eyebrow={@eyebrow} preheader={@preheader}>
      <.paragraph>{@lead}</.paragraph>
      <.paragraph>{@settings}</.paragraph>
      <.button href={@url}>{@action}</.button>
      <.note>{@validity}</.note>
      <.note>{@not_you}</.note>
      <.fallback url={@url} />
    </.layout>
    """
  end
end
