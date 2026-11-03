defmodule PotokIdeWeb.TagLive.Index do
  @moduledoc """
  The tags page. Without tags it is the directory: the profile's private
  tags, which it renames and deletes here, and the public tags in use. With
  tags (`?t=3,7`) it lists what carries every one of them and the profile
  can open, by kind (`kind=values`), optionally inside one group and its
  sub-groups (`group=12`).
  """

  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIde.Social.Value
  alias PotokIde.Tags
  alias PotokIde.Tags.Tag
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.ProfileAuth
  alias PotokIdeWeb.TagComponents

  # URL name, `Tags` kind and stream, in the order shown.
  @kinds [
    {"groups", :group, :tagged_groups},
    {"values", :value, :tagged_values},
    {"files", :attachment, :tagged_files},
    {"events", :event, :tagged_events},
    {"profiles", :profile, :tagged_profiles}
  ]
  @kind_params Map.new(@kinds, fn {param, kind, _stream} -> {param, kind} end)

  @preview_size 5
  @page_size 30

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
      <.page_container id="tags-page">
        <.page_header id="tags-header" icon="hero-hashtag">
          {gettext("Tags")}
          <:subtitle>
            {if @selected_tags == [],
              do: gettext("Pick a tag to see everything that carries it."),
              else: gettext("Everything you can open that carries every chosen tag.")}
          </:subtitle>
        </.page_header>

        <div
          id="tags-filter-bar"
          class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/80 p-3 shadow-sm"
        >
          <div class="flex flex-wrap items-center gap-1.5">
            <span
              :for={tag <- @selected_tags}
              id={"tags-selected-#{tag.id}"}
              class={[
                "inline-flex h-8 items-center gap-1 rounded-full border pl-3 pr-1 text-sm font-semibold",
                TagComponents.chip_class(tag)
              ]}
            >
              <.icon name={TagComponents.tag_icon(tag)} class="size-3.5 opacity-70" />
              <span class="max-w-48 truncate">{tag.name}</span>
              <.link
                id={"tags-selected-remove-#{tag.id}"}
                patch={tags_url(assigns, t: List.delete(Enum.map(@selected_tags, & &1.id), tag.id))}
                aria-label={gettext("Remove tag %{name}", name: tag.name)}
                class="inline-flex size-6 items-center justify-center rounded-full transition hover:bg-base-content/10"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </.link>
            </span>

            <span
              :if={@scope_group}
              id="tags-scope"
              class="inline-flex h-8 items-center gap-1.5 rounded-full border border-amber-500/30 bg-amber-500/10 pl-3 pr-1 text-sm font-semibold text-amber-800 dark:text-amber-200"
            >
              <.icon name="hero-folder-open" class="size-4 opacity-70" />
              <span class="max-w-48 truncate">
                {gettext("In %{group}", group: @scope_group.name)}
              </span>
              <.link
                id="tags-scope-remove"
                patch={tags_url(assigns, group: nil)}
                aria-label={gettext("Search every group")}
                class="inline-flex size-6 items-center justify-center rounded-full transition hover:bg-base-content/10"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </.link>
            </span>

            <.form
              :if={length(@selected_tags) < Tags.max_filter_tags()}
              for={@filter_form}
              id="tags-filter-form"
              phx-change="filter_search"
              phx-submit="filter_search"
              class="min-w-40 flex-1"
            >
              <.input
                field={@filter_form[:q]}
                id="tags-filter-input"
                type="text"
                phx-debounce="200"
                autocomplete="off"
                placeholder={
                  if(@selected_tags == [],
                    do: gettext("Search tags"),
                    else: gettext("Add a tag to narrow down")
                  )
                }
                aria-label={gettext("Search tags")}
                class="h-8 w-full rounded-full border border-transparent bg-transparent px-3 text-sm transition focus:border-base-300 focus:bg-base-100 focus:outline-none"
              />
            </.form>
          </div>

          <ul
            :if={@selected_tags != [] and @filter_suggestions != []}
            id="tags-filter-suggestions"
            class="mt-2 flex flex-wrap gap-1.5 border-t border-base-300/60 pt-2"
          >
            <li :for={tag <- @filter_suggestions}>
              <.link
                id={"tags-filter-suggestion-#{tag.id}"}
                patch={tags_url(assigns, t: Enum.map(@selected_tags, & &1.id) ++ [tag.id])}
                class={[
                  "inline-flex h-7 items-center gap-1 rounded-full border border-dashed px-2.5 text-sm transition hover:-translate-y-px hover:border-solid",
                  TagComponents.chip_class(tag)
                ]}
              >
                <.icon name="hero-plus" class="size-3.5 opacity-70" />
                <span class="max-w-48 truncate">{tag.name}</span>
                <.icon :if={!Tag.public?(tag)} name="hero-lock-closed" class="size-3 opacity-60" />
              </.link>
            </li>
          </ul>
        </div>

        <%= if @selected_tags == [] do %>
          <.directory
            directory={@directory}
            renaming_tag_id={@renaming_tag_id}
            rename_form={@rename_form}
            assigns_for_urls={assigns}
          />
        <% else %>
          <nav
            id="tags-kinds"
            aria-label={gettext("Kinds")}
            class="mb-4 flex gap-1.5 overflow-x-auto pb-1"
          >
            <.link
              id="tags-kind-all"
              patch={tags_url(assigns, kind: nil)}
              class={kind_tab_class(is_nil(@kind))}
            >
              {pgettext("tag kind", "All")}
              <span class="tabular-nums opacity-70">{@counts |> Map.values() |> Enum.sum()}</span>
            </.link>
            <.link
              :for={{param, kind, _stream} <- kinds()}
              id={"tags-kind-#{param}"}
              patch={tags_url(assigns, kind: param)}
              class={kind_tab_class(@kind == kind)}
            >
              <.icon name={kind_icon(kind)} class="size-4" />
              {kind_label(kind)}
              <span class="tabular-nums opacity-70">{Map.get(@counts, kind, 0)}</span>
            </.link>
          </nav>

          <div
            :if={@counts |> Map.values() |> Enum.sum() == 0}
            id="tags-no-results"
            class="flex flex-col items-center gap-2 rounded-3xl border border-dashed border-base-300 px-6 py-12 text-center text-sm text-base-content/60"
          >
            <.icon name="hero-magnifying-glass" class="size-7 text-base-content/35" />
            {gettext("Nothing you can open carries these tags.")}
          </div>

          <section
            :for={{param, kind, stream} <- kinds()}
            :if={(is_nil(@kind) and Map.get(@counts, kind, 0) > 0) or @kind == kind}
            id={"tags-section-#{param}"}
            class="mb-6"
          >
            <h2 class="mb-2 flex items-center gap-2 px-1 text-xs font-semibold uppercase tracking-wide text-base-content/55">
              <.icon name={kind_icon(kind)} class="size-4" />
              {kind_label(kind)}
              <span class="tabular-nums">{Map.get(@counts, kind, 0)}</span>
            </h2>
            <ul id={"tags-results-#{param}"} phx-update="stream" class="space-y-2">
              <li
                id={"tags-results-#{param}-empty"}
                class="hidden only:block px-1 text-sm text-base-content/55"
              >
                {gettext("Nothing here.")}
              </li>
              <li
                :for={{dom_id, item} <- Map.fetch!(@streams, stream)}
                id={dom_id}
                class="rounded-2xl border border-base-300/60 bg-base-100/80 shadow-sm transition hover:border-base-content/20 hover:shadow-md"
              >
                <.result_row kind={kind} item={item} current_profile={@current_profile} />
              </li>
            </ul>
            <div class="mt-2 flex justify-center">
              <.link
                :if={is_nil(@kind) and Map.get(@counts, kind, 0) > length_shown(@shown, kind)}
                id={"tags-show-all-#{param}"}
                patch={tags_url(assigns, kind: param)}
                class="inline-flex items-center gap-1 rounded-full px-3 py-1.5 text-sm font-semibold text-primary transition hover:bg-primary/10"
              >
                {gettext("Show all (%{count})", count: Map.get(@counts, kind, 0))}
                <.icon name="hero-chevron-right" class="size-4" />
              </.link>
              <.button
                :if={@kind == kind and Map.get(@more, kind, false)}
                id={"tags-load-more-#{param}"}
                type="button"
                phx-click="load_more"
                size="sm"
                class="phx-click-loading:animate-pulse"
              >
                {gettext("Load more")}
              </.button>
            </div>
          </section>
        <% end %>
      </.page_container>
    </Layouts.app>
    """
  end

  attr :directory, :map, required: true
  attr :renaming_tag_id, :integer, default: nil
  attr :rename_form, :any, default: nil
  attr :assigns_for_urls, :map, required: true

  defp directory(assigns) do
    ~H"""
    <div id="tags-directory" class="space-y-6">
      <section id="tags-directory-mine">
        <h2 class="mb-2 flex items-center gap-2 px-1 text-xs font-semibold uppercase tracking-wide text-base-content/55">
          <.icon name="hero-lock-closed" class="size-4" />
          {gettext("My private tags")}
        </h2>
        <p
          :if={@directory.mine == []}
          id="tags-directory-mine-empty"
          class="px-1 text-sm text-base-content/55"
        >
          {gettext(
            "No private tags yet. Add one from the # button on a value, file, event, group or member."
          )}
        </p>
        <ul
          :if={@directory.mine != []}
          class="divide-y divide-base-300/60 overflow-hidden rounded-2xl border border-base-300/60 bg-base-100/80 shadow-sm"
        >
          <li
            :for={tag <- @directory.mine}
            id={"tags-mine-#{tag.id}"}
            class="flex items-center gap-2 px-3 py-2"
          >
            <%= if @renaming_tag_id == tag.id do %>
              <.form
                for={@rename_form}
                id={"tags-rename-form-#{tag.id}"}
                phx-submit="rename_tag"
                class="flex flex-1 items-start gap-2"
              >
                <input type="hidden" name="tag_id" value={tag.id} />
                <div class="min-w-0 flex-1">
                  <.input
                    field={@rename_form[:name]}
                    id={"tags-rename-input-#{tag.id}"}
                    type="text"
                    autocomplete="off"
                    maxlength={Tag.max_length()}
                    aria-label={gettext("Tag name")}
                    class="h-9 w-full rounded-full border border-base-300 bg-base-100 px-3 text-sm focus:border-primary/60 focus:outline-none focus:ring-2 focus:ring-primary/20"
                  />
                </div>
                <.button
                  id={"tags-rename-save-#{tag.id}"}
                  type="submit"
                  variant="primary"
                  size="sm"
                  class="mt-0.5"
                >
                  {gettext("Save")}
                </.button>
                <.button
                  id={"tags-rename-cancel-#{tag.id}"}
                  type="button"
                  phx-click="cancel_rename"
                  variant="ghost"
                  size="sm"
                  class="mt-0.5"
                >
                  {gettext("Cancel")}
                </.button>
              </.form>
            <% else %>
              <.link
                id={"tags-mine-link-#{tag.id}"}
                patch={tags_url(@assigns_for_urls, t: [tag.id])}
                class="flex min-w-0 flex-1 items-center gap-2 rounded-full py-1 text-sm font-medium transition hover:text-primary"
              >
                <.icon name="hero-lock-closed" class="size-4 shrink-0 text-base-content/45" />
                <span class="truncate">{tag.name}</span>
              </.link>
              <.icon_button
                id={"tags-rename-#{tag.id}"}
                type="button"
                phx-click="start_rename"
                phx-value-id={tag.id}
                icon="hero-pencil-square"
                label={gettext("Rename tag %{name}", name: tag.name)}
              />
              <.icon_button
                id={"tags-delete-#{tag.id}"}
                type="button"
                phx-click="delete_tag"
                phx-value-id={tag.id}
                data-confirm={
                  gettext("Delete the tag %{name}? It is taken off everything it is on.",
                    name: tag.name
                  )
                }
                icon="hero-trash"
                label={gettext("Delete tag %{name}", name: tag.name)}
                variant="danger"
              />
            <% end %>
          </li>
        </ul>
      </section>

      <section id="tags-directory-public">
        <h2 class="mb-2 flex items-center gap-2 px-1 text-xs font-semibold uppercase tracking-wide text-base-content/55">
          <.icon name="hero-hashtag" class="size-4" />
          {gettext("Public tags")}
        </h2>
        <p
          :if={@directory.public == []}
          id="tags-directory-public-empty"
          class="px-1 text-sm text-base-content/55"
        >
          {gettext("No public tags yet.")}
        </p>
        <div :if={@directory.public != []} class="flex flex-wrap gap-1.5">
          <.link
            :for={tag <- @directory.public}
            id={"tags-public-#{tag.id}"}
            patch={tags_url(@assigns_for_urls, t: [tag.id])}
            class={[
              "inline-flex h-8 items-center gap-1 rounded-full border px-3 text-sm font-semibold transition duration-150 ease-out hover:-translate-y-px active:scale-95",
              TagComponents.chip_class(tag)
            ]}
          >
            <.icon name="hero-hashtag" class="size-3.5 opacity-70" />
            <span class="max-w-56 truncate">{tag.name}</span>
          </.link>
        </div>
      </section>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :item, :any, required: true
  attr :current_profile, :map, required: true

  defp result_row(%{kind: :group} = assigns) do
    ~H"""
    <div class="px-2 py-2">
      <Components.group_identity
        group={@item}
        current_profile={@current_profile}
        avatar_size="size-10"
        text_class="text-sm"
      />
      <TagComponents.tag_chips
        id={"tagged-group-tags-#{@item.id}"}
        tags={@item.tags}
        class="mt-1 pl-13"
      />
    </div>
    """
  end

  defp result_row(%{kind: :profile} = assigns) do
    ~H"""
    <div class="px-2 py-2">
      <Components.profile_identity
        profile={@item}
        me={@item.id == @current_profile.id}
        avatar_size="size-10"
        current_profile={@current_profile}
        direct_group_link={@item.id != @current_profile.id}
      />
      <TagComponents.tag_chips
        id={"tagged-profile-tags-#{@item.id}"}
        tags={@item.tags}
        class="mt-1 pl-13"
      />
    </div>
    """
  end

  defp result_row(%{kind: :value} = assigns) do
    ~H"""
    <.link
      navigate={~p"/groups/#{@item.group_id}/values?value=#{@item.id}"}
      class="block rounded-2xl px-3 py-2.5"
    >
      <span class="flex flex-wrap items-center gap-x-1.5 text-xs text-base-content/55">
        <span class="font-semibold text-base-content/80">@{@item.creator.username}</span>
        <span aria-hidden="true">·</span>
        <span class="truncate">{@item.group.name}</span>
        <span aria-hidden="true">·</span>
        <Components.local_time id={"tagged-value-time-#{@item.id}"} datetime={@item.inserted_at} />
      </span>
      <span class="mt-1 line-clamp-2 block text-sm text-base-content">
        {Value.excerpt(@item, 240) || gettext("(no text)")}
      </span>
    </.link>
    <TagComponents.tag_chips
      id={"tagged-value-tags-#{@item.id}"}
      tags={@item.tags}
      class="px-3 pb-2.5"
    />
    """
  end

  defp result_row(%{kind: :attachment} = assigns) do
    ~H"""
    <a
      href={~p"/files/#{@item.id}"}
      target="_blank"
      rel="noopener"
      class="flex items-center gap-3 rounded-2xl px-3 py-2.5"
    >
      <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-xl bg-base-200 text-base-content/60">
        <.icon name={Components.file_icon(@item.content_type)} class="size-4" />
      </span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm font-medium">{@item.filename}</span>
        <span class="flex flex-wrap items-center gap-x-1.5 text-xs text-base-content/55">
          <span>{@item.profile.username}</span>
          <span aria-hidden="true">·</span>
          <span class="truncate">{@item.group.name}</span>
          <span aria-hidden="true">·</span>
          <span class="tabular-nums">{Components.format_bytes(@item.byte_size)}</span>
        </span>
      </span>
    </a>
    <TagComponents.tag_chips
      id={"tagged-file-tags-#{@item.id}"}
      tags={@item.tags}
      class="px-3 pb-2.5"
    />
    """
  end

  defp result_row(%{kind: :event} = assigns) do
    ~H"""
    <.link
      navigate={~p"/groups/#{@item.group_id}/calendar?event=#{@item.id}"}
      class="flex items-center gap-3 rounded-2xl px-3 py-2.5"
    >
      <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary">
        <.icon name="hero-calendar-days" class="size-5" />
      </span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm font-medium">{@item.title}</span>
        <span class="flex flex-wrap items-center gap-x-1.5 text-xs text-base-content/55">
          <span class="truncate">{@item.group.name}</span>
          <span aria-hidden="true">·</span>
          <Components.local_time id={"tagged-event-time-#{@item.id}"} datetime={@item.starts_at} />
        </span>
      </span>
    </.link>
    <TagComponents.tag_chips
      id={"tagged-event-tags-#{@item.id}"}
      tags={@item.tags}
      class="px-3 pb-2.5"
    />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      Enum.reduce(@kinds, socket, fn {_param, kind, stream}, socket ->
        stream_configure(socket, stream, dom_id: &"tagged-#{kind}-#{&1.id}")
      end)

    {:ok,
     socket
     |> put_private(:previous_current_profile, socket.assigns.current_profile)
     |> assign(
       selected_tags: [],
       kind: nil,
       scope_group: nil,
       counts: %{},
       more: %{},
       shown: %{},
       oldest: %{},
       directory: %{mine: [], public: []},
       renaming_tag_id: nil,
       rename_form: nil,
       filter_form: to_form(%{"q" => ""}, as: :filter),
       filter_suggestions: []
     )
     |> reset_streams()
     |> ProfileAuth.sync_profile_subscription()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    profile = socket.assigns.current_profile

    tags =
      params
      |> Map.get("t", "")
      |> parse_ids()
      |> then(&Tags.get_visible_tags(profile, &1))
      |> Enum.take(Tags.max_filter_tags())

    {:noreply,
     socket
     |> assign(:selected_tags, tags)
     |> assign(:kind, Map.get(@kind_params, params["kind"]))
     |> assign(:scope_group, scope_group(profile, params["group"]))
     |> assign(:renaming_tag_id, nil)
     |> assign(:filter_form, to_form(%{"q" => ""}, as: :filter))
     |> load()}
  end

  @impl true
  def handle_event("filter_search", %{"filter" => %{"q" => query}}, socket) do
    socket = assign(socket, :filter_form, to_form(%{"q" => query}, as: :filter))

    if socket.assigns.selected_tags == [] do
      {:noreply, load_directory(socket, query)}
    else
      {:noreply, put_filter_suggestions(socket, query)}
    end
  end

  def handle_event("load_more", _params, %{assigns: %{kind: kind}} = socket)
      when not is_nil(kind) do
    {:noreply, load_kind(socket, kind, @page_size, socket.assigns.oldest[kind])}
  end

  def handle_event("load_more", _params, socket), do: {:noreply, socket}

  def handle_event("start_rename", %{"id" => id}, socket) do
    with {tag_id, ""} <- Integer.parse(id),
         %Tag{} = tag <- Enum.find(socket.assigns.directory.mine, &(&1.id == tag_id)) do
      {:noreply,
       socket
       |> assign(:renaming_tag_id, tag.id)
       |> assign(:rename_form, to_form(%{"name" => tag.name}, as: :tag))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, :renaming_tag_id, nil)}

  def handle_event("rename_tag", %{"tag_id" => id, "tag" => %{"name" => name}}, socket) do
    with {tag_id, ""} <- Integer.parse(id),
         {:ok, _tag} <- Tags.rename_private_tag(socket.assigns.current_profile, tag_id, name) do
      {:noreply,
       socket
       |> assign(:renaming_tag_id, nil)
       |> load_directory(socket.assigns.filter_form[:q].value)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :rename_form, to_form(Map.put(changeset, :action, :validate), as: :tag))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("That tag is no longer available."))}
    end
  end

  def handle_event("delete_tag", %{"id" => id}, socket) do
    with {tag_id, ""} <- Integer.parse(id),
         {:ok, _tag} <- Tags.delete_private_tag(socket.assigns.current_profile, tag_id) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Tag deleted."))
       |> load_directory(socket.assigns.filter_form[:q].value)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("That tag is no longer available."))}
    end
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

        # Private tags belong to the profile, so the filter starts over.
        {:noreply, push_patch(socket, to: ~p"/tags")}
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

  ## Loading

  defp load(%{assigns: %{selected_tags: []}} = socket) do
    socket
    |> reset_streams()
    |> assign(counts: %{}, more: %{}, shown: %{}, oldest: %{}, filter_suggestions: [])
    |> load_directory("")
  end

  defp load(socket) do
    %{current_profile: profile, selected_tags: tags, scope_group: group, kind: kind} =
      socket.assigns

    counts =
      Map.new(@kinds, fn {_param, kind, _stream} ->
        {kind, Tags.count_tagged(profile, kind, tags, group: group)}
      end)

    socket =
      socket
      |> reset_streams()
      |> assign(counts: counts, more: %{}, shown: %{}, oldest: %{})
      |> put_filter_suggestions("")

    case kind do
      nil ->
        @kinds
        |> Enum.filter(fn {_param, kind, _stream} -> counts[kind] > 0 end)
        |> Enum.reduce(socket, fn {_param, kind, _stream}, socket ->
          load_kind(socket, kind, @preview_size, nil)
        end)

      kind ->
        load_kind(socket, kind, @page_size, nil)
    end
  end

  defp load_kind(socket, kind, limit, before_id) do
    %{current_profile: profile, selected_tags: tags, scope_group: group} = socket.assigns

    {items, more?} =
      Tags.list_tagged(profile, kind, tags, group: group, limit: limit, before_id: before_id)

    socket
    |> stream(stream_name(kind), items)
    |> update(:more, &Map.put(&1, kind, more?))
    |> update(:shown, &Map.update(&1, kind, length(items), fn shown -> shown + length(items) end))
    |> update(:oldest, fn oldest ->
      case List.last(items) do
        nil -> oldest
        item -> Map.put(oldest, kind, item.id)
      end
    end)
  end

  defp reset_streams(socket) do
    Enum.reduce(@kinds, socket, fn {_param, _kind, stream}, socket ->
      stream(socket, stream, [], reset: true)
    end)
  end

  defp load_directory(socket, search) do
    assign(socket, :directory, Tags.list_directory(socket.assigns.current_profile, search))
  end

  defp put_filter_suggestions(socket, query) do
    selected = MapSet.new(socket.assigns.selected_tags, & &1.id)

    suggestions =
      socket.assigns.current_profile
      |> Tags.suggest_tags(query, 16)
      |> Enum.reject(&MapSet.member?(selected, &1.id))
      |> Enum.take(10)

    assign(socket, :filter_suggestions, suggestions)
  end

  defp scope_group(profile, param) do
    with param when is_binary(param) <- param,
         {group_id, ""} <- Integer.parse(param),
         %{is_root: false} = group <- Social.get_visible_group(profile, group_id) do
      group
    else
      _ -> nil
    end
  end

  defp parse_ids(param) do
    param
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case Integer.parse(String.trim(part)) do
        {id, ""} when id > 0 -> [id]
        _ -> []
      end
    end)
  end

  ## URLs and labels

  # The page's URL with some of its params changed.
  defp tags_url(assigns, changes) do
    current = %{
      t: Enum.map(assigns.selected_tags, & &1.id),
      kind: kind_param(assigns.kind),
      group: assigns.scope_group && assigns.scope_group.id
    }

    params = Map.merge(current, Map.new(changes))

    query =
      [
        t: params.t |> Enum.uniq() |> Enum.join(","),
        kind: if(params.t == [], do: nil, else: params.kind),
        group: params.group
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    if query == [], do: ~p"/tags", else: ~p"/tags?#{query}"
  end

  defp kinds, do: @kinds

  defp stream_name(kind) do
    {_param, _kind, stream} = List.keyfind(@kinds, kind, 1)
    stream
  end

  defp kind_param(nil), do: nil

  defp kind_param(kind) do
    {param, _kind, _stream} = List.keyfind(@kinds, kind, 1)
    param
  end

  defp length_shown(shown, kind), do: Map.get(shown, kind, 0)

  defp kind_label(:group), do: pgettext("tag kind", "Groups")
  defp kind_label(:value), do: pgettext("tag kind", "Values")
  defp kind_label(:attachment), do: pgettext("tag kind", "Files")
  defp kind_label(:event), do: pgettext("tag kind", "Events")
  defp kind_label(:profile), do: pgettext("tag kind", "Profiles")

  defp kind_icon(:group), do: "hero-user-group"
  defp kind_icon(:value), do: "hero-chat-bubble-oval-left-ellipsis"
  defp kind_icon(:attachment), do: "hero-paper-clip"
  defp kind_icon(:event), do: "hero-calendar-days"
  defp kind_icon(:profile), do: "hero-user"

  defp kind_tab_class(active?) do
    [
      "inline-flex h-9 shrink-0 items-center gap-1.5 rounded-full border px-3.5 text-sm font-semibold transition duration-150 ease-out active:scale-95",
      if(active?,
        do: "border-base-content bg-base-content text-base-100 shadow-sm",
        else:
          "border-base-300 bg-base-100/80 text-base-content/70 hover:border-base-content/25 hover:text-base-content"
      )
    ]
  end
end
