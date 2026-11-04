defmodule PotokIdeWeb.ShareLive do
  @moduledoc """
  "Share to Potok": where content shared from another app lands. The content
  stays on the device (`assets/js/share_inbox.js`) and the `SharePreview`
  hook sends only what it is: the text and the names, types and sizes of the
  files. Picking a group opens its chat with `?share=`, and the composer
  there takes the text and the files.
  """

  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.ProfileAuth

  # The device names the share; `GroupLive.Show` checks `?share=` the same way.
  @share_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @max_text_length 4_000
  @max_files 50

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
      full_width
    >
      <.page_container id="share-page">
        <div id="share-inbox" phx-hook="SharePreview">
          <.page_header id="share-header" icon="hero-arrow-up-on-square">
            {gettext("Share to Potok")}
            <:subtitle>{gettext("Pick the group or conversation to post it in.")}</:subtitle>
            <:actions>
              <.button id="share-cancel" type="button" variant="ghost" size="sm">
                <.icon name="hero-x-mark" class="size-4" />
                {gettext("Cancel")}
              </.button>
            </:actions>
          </.page_header>

          <div
            :if={@share_state == :loading}
            id="share-loading"
            class="flex items-center gap-3 rounded-3xl border border-base-300/70 bg-base-100/80 p-5 text-sm text-base-content/65 shadow-sm"
          >
            <span class="loading loading-spinner loading-sm text-primary"></span>
            {gettext("Getting what you shared…")}
          </div>

          <div
            :if={@share_state == :missing}
            id="share-missing"
            class="flex flex-col items-center gap-3 rounded-3xl border border-dashed border-base-300 bg-base-100/60 px-6 py-10 text-center"
          >
            <span class="inline-flex size-12 items-center justify-center rounded-2xl bg-base-200 text-base-content/65">
              <.icon name="hero-inbox" class="size-6" />
            </span>
            <p class="font-semibold">{gettext("Nothing to share")}</p>
            <p class="max-w-sm text-sm text-base-content/65">
              {gettext("Share a link, text or files from another app and pick Potok.")}
            </p>
            <.button
              id="share-missing-home"
              navigate={~p"/groups"}
              variant="primary"
              size="sm"
              class="mt-1"
            >
              {gettext("Go to groups")}
            </.button>
          </div>

          <section
            :if={@share_state == :ready}
            id="share-preview"
            phx-mounted={
              JS.transition(
                {"transition ease-out duration-200", "opacity-0 translate-y-1",
                 "opacity-100 translate-y-0"}
              )
            }
            class="mb-5 overflow-hidden rounded-3xl border border-base-300/70 bg-base-100 shadow-sm"
          >
            <%!-- Kept on one line: `whitespace-pre-line` would show the template's line breaks. --%>
            <p
              :if={@share.text != ""}
              id="share-preview-text"
              class="line-clamp-6 whitespace-pre-line px-4 py-3 text-sm text-base-content/80 wrap-break-word"
              phx-no-format
            >{@share.text}</p>
            <ul
              :if={@share.files != []}
              id="share-preview-files"
              class={[
                "flex flex-col gap-1.5 p-3",
                @share.text != "" && "border-t border-base-300/60"
              ]}
            >
              <li
                :for={{file, index} <- Enum.with_index(@share.files)}
                id={"share-preview-file-#{index}"}
                class="flex items-center gap-3 rounded-2xl bg-base-200/60 py-2 pr-3 pl-2.5"
              >
                <span class="inline-flex size-9 shrink-0 items-center justify-center rounded-xl bg-base-100 text-base-content/65">
                  <.icon name={Components.file_icon(file.type)} class="size-5" />
                </span>
                <p class="min-w-0 flex-1 truncate text-sm font-medium">{file.name}</p>
                <span class="shrink-0 text-xs tabular-nums text-base-content/65">
                  {Components.format_bytes(file.size)}
                </span>
              </li>
            </ul>
          </section>

          <div :if={@share_state == :ready} id="share-targets">
            <.form
              for={@search_form}
              id="share-search-form"
              phx-change="search"
              phx-submit="search"
              class="mb-3"
            >
              <.input
                field={@search_form[:q]}
                id="share-search-input"
                type="search"
                phx-debounce="200"
                autocomplete="off"
                placeholder={gettext("Search groups and people")}
                aria-label={gettext("Search groups and people")}
                class="h-11 w-full rounded-full border border-base-300 bg-base-100 px-4 text-sm shadow-sm transition focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
              />
            </.form>

            <ul id="share-groups" phx-update="stream" class="flex flex-col gap-1">
              <li
                id="share-groups-empty"
                class="hidden rounded-3xl border border-dashed border-base-300 px-6 py-8 text-center text-sm text-base-content/65 only:block"
              >
                {gettext("No groups where you can post.")}
              </li>
              <li :for={{dom_id, group} <- @streams.groups} id={dom_id}>
                <Components.group_identity
                  group={group}
                  current_profile={@current_profile}
                  highlight_query={@search_form[:q].value}
                  navigate={~p"/groups/#{group.id}/values?#{[share: @share.id]}"}
                >
                  <:subtitle :if={group_subtitle(group)}>
                    <span class="truncate text-xs text-base-content/65">
                      {group_subtitle(group)}
                    </span>
                  </:subtitle>
                </Components.group_identity>
              </li>
            </ul>
          </div>
        </div>
      </.page_container>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> put_private(:previous_current_profile, socket.assigns.current_profile)
     |> assign(share_state: :loading, share: nil, search_form: search_form(""))
     |> stream_configure(:groups, dom_id: &"share-group-#{&1.id}")
     |> stream(:groups, [])
     |> ProfileAuth.sync_profile_subscription()}
  end

  @impl true
  def handle_event("share_loaded", %{"id" => id} = params, socket) when is_binary(id) do
    share = %{id: id, text: clean_text(params["text"]), files: clean_files(params["files"])}

    if Regex.match?(@share_id, id) and (share.text != "" or share.files != []) do
      {:noreply,
       socket
       |> assign(share_state: :ready, share: share)
       |> load_groups()}
    else
      {:noreply, assign(socket, share_state: :missing, share: nil)}
    end
  end

  def handle_event("share_loaded", _params, socket),
    do: {:noreply, assign(socket, share_state: :missing, share: nil)}

  def handle_event("share_missing", _params, socket),
    do: {:noreply, assign(socket, share_state: :missing, share: nil)}

  def handle_event("share_cancelled", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/groups")}

  def handle_event("search", %{"share_search" => %{"q" => query}}, socket)
      when is_binary(query) do
    {:noreply,
     socket
     |> assign(:search_form, search_form(query))
     |> load_groups()}
  end

  @impl true
  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id do
    previous_profile = socket.private[:previous_current_profile]

    ProfileAuth.handle_current_profile_change(
      socket,
      fn socket, current_profile ->
        socket =
          socket
          |> put_private(:previous_current_profile, current_profile)
          |> ProfileAuth.sync_profile_subscription(previous_profile)

        # Memberships belong to the profile, so the list is the new one's.
        {:noreply, load_groups(socket)}
      end,
      fn socket ->
        socket =
          socket
          |> put_private(:previous_current_profile, nil)
          |> ProfileAuth.sync_profile_subscription(previous_profile)

        {:noreply, push_navigate(socket, to: ~p"/profiles")}
      end
    )
  end

  # Badge updates and the like for the current profile; the page itself
  # does not change with them.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_groups(%{assigns: %{share: nil}} = socket), do: socket

  defp load_groups(socket) do
    groups =
      Social.list_share_target_groups(socket.assigns.current_profile,
        search: socket.assigns.search_form[:q].value
      )

    stream(socket, :groups, groups, reset: true)
  end

  defp search_form(query), do: to_form(%{"q" => query}, as: :share_search)

  # Direct conversations say so; other groups name the group they are in,
  # unless that is the root, which holds them all.
  defp group_subtitle(%{is_direct: true}), do: gettext("Direct conversation")
  defp group_subtitle(%{parent: %{is_root: false, name: name}}), do: name
  defp group_subtitle(_group), do: nil

  defp clean_text(text) when is_binary(text),
    do: text |> String.trim() |> String.slice(0, @max_text_length)

  defp clean_text(_text), do: ""

  defp clean_files(files) when is_list(files) do
    files
    |> Enum.take(@max_files)
    |> Enum.flat_map(fn
      %{"name" => name} = file when is_binary(name) and name != "" ->
        [
          %{
            name: String.slice(name, 0, 255),
            type: if(is_binary(file["type"]), do: String.slice(file["type"], 0, 255), else: ""),
            size: if(is_integer(file["size"]) and file["size"] >= 0, do: file["size"], else: nil)
          }
        ]

      _file ->
        []
    end)
  end

  defp clean_files(_files), do: []
end
