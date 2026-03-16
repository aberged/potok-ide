defmodule PotokIdeWeb.ProfileLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.Profile

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <.header>
          Profiles
          <:subtitle>Pick the profile you want to use, or create a new one.</:subtitle>
        </.header>
        
        <div :if={@current_profile} class="alert">
          <.icon name="hero-user-circle" class="size-5 shrink-0" />
          <div>Current profile: <span class="font-semibold">{@current_profile.username}</span></div>
        </div>
        
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title">Your profiles</h3>
            
            <div :if={@profiles == []} class="text-base-content/70">No profiles yet.</div>
            
            <ul :if={@profiles != []} class="space-y-2">
              <li :for={profile <- @profiles} class="flex items-center justify-between">
                <div>
                  <div class="font-semibold">{profile.username}</div>
                  
                  <div class="text-xs text-base-content/60">{Atom.to_string(profile.sharing)}</div>
                </div>
                
                <.button
                  :if={is_nil(@current_profile) or @current_profile.id != profile.id}
                  phx-click="use"
                  phx-value-id={profile.id}
                  variant="primary"
                >
                  Use
                </.button>
                <span
                  :if={!is_nil(@current_profile) and @current_profile.id == profile.id}
                  class="badge"
                >
                  Active
                </span>
              </li>
            </ul>
            
            <div class="mt-4">
              <.button navigate={~p"/groups"} variant="primary">Go to Root Group</.button>
            </div>
          </div>
        </div>
        
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title">Create profile</h3>
            
            <.form for={@form} phx-change="validate" phx-submit="create">
              <.input field={@form[:username]} label="Username" required />
              <.input field={@form[:profile_picture_url]} label="Profile picture URL" type="url" />
              <.input
                field={@form[:description_format]}
                label="Description format"
                type="select"
                options={@description_format_options}
              /> <.input field={@form[:description]} label="Description" type="textarea" />
              <.input
                field={@form[:sharing]}
                label="Sharing"
                type="select"
                options={@sharing_options}
              /> <.button phx-disable-with="Creating..." variant="primary">Create</.button>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_scope.account

    changeset = Profile.changeset(%Profile{}, %{})

    {:ok,
     socket
     |> assign(:profiles, Social.list_profiles_for_account(account))
     |> assign(:form, to_form(changeset))
     |> assign(:description_format_options, Markdown: :markdown, HTML: :html)
     |> assign(:sharing_options, Unique: :unique, Shared: :shared)}
  end

  @impl true
  def handle_event("validate", %{"profile" => attrs}, socket) do
    changeset =
      %Profile{}
      |> Profile.changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("create", %{"profile" => attrs}, socket) do
    account = socket.assigns.current_scope.account

    case Social.create_profile_for_account(account, attrs) do
      {:ok, profile} ->
        {:ok, account} = Accounts.set_current_profile(account, profile)

        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | account: account})
         |> assign(:current_profile, profile)
         |> assign(:profiles, Social.list_profiles_for_account(account))
         |> put_flash(:info, "Profile created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("use", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account

    case Social.get_profile_for_account(account, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "That profile is not available for this account.")}

      profile ->
        {:ok, account} = Accounts.set_current_profile(account, profile)

        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | account: account})
         |> assign(:current_profile, profile)
         |> put_flash(:info, "Profile selected.")}
    end
  end
end
