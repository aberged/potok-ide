defmodule PotokIdeWeb.ProfileLive.Card do
  @moduledoc """
  A profile's card at `/u/:username`, as the current profile sees it
  (`PotokIde.Social.ProfileDetails.card/3`), for whoever may find it by its
  name (`PotokIde.Social.Discovery`). An unknown name, a profile hidden from
  the viewer, a process and a deleted profile all show the same "not found".
  Looking names up counts against the account's limit (`:profile_lookup`).
  """

  use PotokIdeWeb, :live_view

  alias PotokIde.RateLimit
  alias PotokIde.Social
  alias PotokIde.Social.{Discovery, Profile, ProfileDetails, ProfileFacts}
  alias PotokIdeWeb.{ProfileCard, RateLimited}

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
            :if={@loading?}
            id="profile-card-loading"
            class="rounded-3xl border border-base-300/70 bg-base-100 p-5 shadow-sm sm:p-6"
            aria-hidden="true"
          >
            <div class="flex items-center gap-3">
              <div class="size-16 shrink-0 animate-pulse rounded-full bg-base-200"></div>
              <div class="h-5 w-32 animate-pulse rounded-full bg-base-200"></div>
            </div>
          </section>

          <section
            :if={!@card and !@loading?}
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
    socket = assign(socket, :page_title, username)

    # The lookup counts once, on the page that stays. The first HTML looks
    # nothing up, or plain requests would try names without any limit.
    if connected?(socket) do
      case RateLimit.hit(:profile_lookup, socket.assigns.current_scope.account.id) do
        :ok ->
          {:ok, assign(socket, card: load_card(socket, username), loading?: false)}

        {:error, :rate_limited, retry_after} ->
          {:ok,
           socket
           |> assign(card: nil, loading?: false)
           |> put_flash(:error, RateLimited.message(retry_after))}
      end
    else
      {:ok, assign(socket, card: nil, loading?: true)}
    end
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
    %{current_scope: %{account: account}, current_profile: viewer} = socket.assigns

    with %Profile{kind: :person} = target <- Social.get_profile_by_username(username),
         facts = ProfileFacts.load(account, viewer, target),
         true <- Discovery.may_find?(facts, target, :username) do
      ProfileDetails.card(facts, viewer, target)
    else
      _hidden_or_none -> nil
    end
  end
end
