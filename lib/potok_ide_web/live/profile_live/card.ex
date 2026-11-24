defmodule PotokIdeWeb.ProfileLive.Card do
  @moduledoc """
  A profile's card at `/u/:username`, as the current profile sees it
  (`PotokIde.Social.ProfileDetails.card/3`). An unknown name, a process and a
  deleted profile all show the same "not found".
  """

  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIde.Social.{Profile, ProfileDetails}
  alias PotokIdeWeb.ProfileCard

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_profile={@current_profile}
      current_locale={@current_locale}
      available_locales={@available_locales}
      pending_invitations_count={@pending_invitations_count}
      pending_group_join_requests_count={@pending_group_join_requests_count}
      root_group_unread_count={@root_group_unread_count}
      unread_notices_count={@unread_notices_count}
    >
      <.page_container id="profile-card-page">
        <div class="mx-auto w-full max-w-md">
          <section
            :if={@card}
            class="rounded-3xl border border-base-300/70 bg-base-100 p-5 shadow-sm sm:p-6"
          >
            <ProfileCard.profile_card id="profile-card" card={@card} />
          </section>

          <section
            :if={!@card}
            id="profile-card-missing"
            class="rounded-3xl border border-dashed border-base-300 bg-base-100/70 p-6 text-center"
          >
            <.icon name="hero-user-circle" class="mx-auto size-10 text-base-content/40" />
            <h1 class="mt-2 text-lg font-semibold">{gettext("No such profile")}</h1>
            <p class="mt-1 text-sm text-base-content/65">
              {gettext("Check the name, or ask the person to write to you first.")}
            </p>
          </section>
        </div>
      </.page_container>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, username)
     |> assign(:card, load_card(socket, username))}
  end

  @impl true
  def handle_event("profile_card_message", _params, socket) do
    case socket.assigns.card do
      %{can_message?: true, profile: target} ->
        case Social.get_or_create_direct_group(socket.assigns.current_profile, target) do
          {:ok, direct} ->
            {:noreply, push_navigate(socket, to: ~p"/groups/#{direct.id}/values")}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, gettext("Unable to open a direct group right now."))}
        end

      _no_card ->
        {:noreply, socket}
    end
  end

  defp load_card(socket, username) do
    case Social.get_profile_by_username(username) do
      %Profile{kind: :person} = target ->
        ProfileDetails.card(
          socket.assigns.current_scope.account,
          socket.assigns.current_profile,
          target
        )

      _none ->
        nil
    end
  end
end
