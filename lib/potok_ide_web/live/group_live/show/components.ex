defmodule PotokIdeWeb.GroupLive.Show.Components do
  use PotokIdeWeb, :html

  alias PotokIde.Social

  import Phoenix.HTML, only: [raw: 1]

  attr :id, :string, required: true
  attr :datetime, :any, required: true
  attr :class, :any, default: nil

  def local_time(assigns) do
    assigns = assign(assigns, :iso8601, datetime_to_iso8601(assigns.datetime))

    ~H"""
    <time
      id={@id}
      phx-hook=".LocalTime"
      datetime={@iso8601}
      data-utc={@iso8601}
      class={@class}
    >
      {Calendar.strftime(datetime_to_utc_datetime(@datetime), "%Y-%m-%d %H:%M UTC")}
    </time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      const formatter = new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
        hour12: false,
      })

      const renderLocalTime = (el) => {
        const utcValue = el.dataset.utc
        if (!utcValue) return

        const date = new Date(utcValue)
        if (Number.isNaN(date.getTime())) return

        el.textContent = formatter.format(date).replace(",", "")
      }

      export default {
        mounted() {
          renderLocalTime(this.el)
        },

        updated() {
          renderLocalTime(this.el)
        },
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :tab, :string, required: true
  attr :active_tab, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :icon_class, :string, default: "size-4"

  def group_tab_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      data-dropdown-close
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        if(@icon != nil and (@label == nil or @label == ""), do: "", else: "w-full"),
        "flex flex-row items-center rounded-md px-4 py-2 text-left text-sm font-medium transition-colors",
        if(@active_tab == @tab,
          do: "bg-base-content text-base-100 shadow-sm",
          else: "bg-base-200 text-base-content/70 hover:bg-base-300 hover:text-base-content"
        )
      ]}
    >
      <.icon :if={@icon} name={@icon} class={@icon_class} />
      <span :if={@label != nil and @label != ""} class="ml-2 truncate">{@label}</span>
    </button>
    """
  end

  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :id, :string, default: "group-path"
  attr :class, :any, default: nil

  def group_path(assigns) do
    assigns =
      assign(
        assigns,
        :group_path,
        Social.list_visible_group_path_for_profile(assigns.group, assigns.current_profile)
      )

    ~H"""
    <div id={@id} class={["px-4 py-4 text-sm text-base-content/60 relative z-40", @class]}>
      <nav
        aria-label={gettext("Current group path")}
        class="flex flex-wrap items-center align-center gap-x-2 gap-y-1"
      >
        <%= for {path_group, idx} <- Enum.with_index(@group_path) do %>
          <%= if idx > 0 do %>
            <span aria-hidden="true" class="text-base-content/35">/</span>
          <% end %>

          <%= if path_group.id == @group.id do %>
            <span class="font-medium text-base-content">
              {group_identity_name(path_group, @current_profile)}
            </span>
          <% else %>
            <.link
              navigate={~p"/groups/#{path_group.id}/sub_groups"}
              class="transition-colors hover:text-base-content"
            >
              {if path_group.is_root,
                do: "",
                else: group_identity_name(path_group, @current_profile)}
              <.icon :if={path_group.is_root} name="hero-globe-alt" class="size-4" />
            </.link>
          <% end %>
        <% end %>
      </nav>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :data, :any, required: true
  attr :label, :string, default: "assigns"
  attr :class, :any, default: nil
  attr :open, :boolean, default: false

  def inspect_tree(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-2xl border border-base-300/80 bg-base-100/80 p-3 font-mono text-xs text-base-content/80 shadow-sm",
        @class
      ]}
    >
      <details open={@open}>
        <summary class="cursor-pointer select-none font-semibold text-base-content">{@label}</summary>

        <div class="mt-3 overflow-auto"><.inspect_tree_node label={@label} value={@data} /></div>
      </details>
    </div>
    """
  end

  attr :profile, :map, required: true
  attr :avatar_size, :string, default: "size-11"
  attr :text_class, :string, default: "text-sm"
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :me, :boolean, default: false
  attr :online?, :boolean, default: false
  attr :presence_badge_id, :string, default: nil
  attr :sharing_badge_text_class, :string, default: "text-xs"
  attr :current_profile, :map, default: nil
  attr :direct_group_link, :boolean, default: false

  def profile_identity(assigns) do
    ~H"""
    <.link
      :if={profile_identity_clickable?(@profile, @current_profile, @direct_group_link)}
      navigate={~p"/profiles/#{@profile.id}/direct"}
      class="block rounded-2xl px-1 py-1 transition-colors hover:bg-base-100/70 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
    >
      <.profile_identity_content
        profile={@profile}
        avatar_size={@avatar_size}
        text_class={@text_class}
        title={@title}
        subtitle={@subtitle}
        me={@me}
        online?={@online?}
        presence_badge_id={@presence_badge_id}
        sharing_badge_text_class={@sharing_badge_text_class}
      />
    </.link>
    <.profile_identity_content
      :if={!profile_identity_clickable?(@profile, @current_profile, @direct_group_link)}
      profile={@profile}
      avatar_size={@avatar_size}
      text_class={@text_class}
      title={@title}
      subtitle={@subtitle}
      me={@me}
      online?={@online?}
      presence_badge_id={@presence_badge_id}
      sharing_badge_text_class={@sharing_badge_text_class}
    />
    """
  end

  attr :profile, :map, required: true
  attr :avatar_size, :string, default: "size-11"
  attr :text_class, :string, default: "text-sm"
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :me, :boolean, default: false
  attr :online?, :boolean, default: false
  attr :presence_badge_id, :string, default: nil
  attr :sharing_badge_text_class, :string, default: "text-xs"

  defp profile_identity_content(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-3">
      <div class="relative">
        <%= if avatar_url = profile_picture_url(@profile) do %>
          <img
            src={avatar_url}
            alt={@profile.username}
            class={[
              @avatar_size,
              "shrink-0 rounded-full border border-base-300 bg-base-100 object-cover shadow-sm"
            ]}
          />
        <% else %>
          <div class={[
            @avatar_size,
            "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-400 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
          ]}>
            {profile_initials(@profile.username)}
          </div>
        <% end %>

        <div class={[@sharing_badge_text_class, "absolute", "bottom-0", "left-0", "-ml-1", "-mb-1"]}>
          {if @profile.sharing == :shared,
            do: "👨‍👨‍👦‍👦",
            else: ""}
        </div>
      </div>

      <div class="min-w-0">
        <div
          :if={@title}
          class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/45"
        >
          {@title}
        </div>

        <div class={[
          @text_class,
          "truncate font-semibold text-base-content",
          if(@me, do: "italic text-success", else: "")
        ]}>
          {@profile.username}
        </div>

        <div :if={@subtitle} class="truncate text-xs text-base-content/60">{@subtitle}</div>

        <div
          :if={@online?}
          id={@presence_badge_id}
          class="mt-1 inline-flex items-center gap-1.5 rounded-full bg-emerald-500/12 px-2 py-0.5 text-[11px] font-medium text-emerald-700"
        >
          <span class="size-2 rounded-full bg-emerald-500" /> <span>{gettext("Online")}</span>
        </div>
      </div>
    </div>
    """
  end

  defp profile_identity_clickable?(profile, current_profile, direct_group_link?) do
    direct_group_link? and
      match?(%{id: current_profile_id} when current_profile_id != profile.id, current_profile)
  end

  attr :group, :map, required: true
  attr :avatar_size, :string, default: "size-11"
  attr :text_class, :string, default: "text-sm"
  attr :pending_join_requests_count, :integer, default: 0
  attr :unread_count, :integer, default: 0
  attr :current_profile, :map, default: nil

  def group_identity(assigns) do
    ~H"""
    <.link
      navigate={~p"/groups/#{@group.id}"}
      class="flex justify-start rounded-full w-full justify-items-start active:bg-base-200 hover:bg-base-100 pr-4"
    >
      <div class="flex min-w-0 items-center gap-3">
        <div class="relative shrink-0">
          <%= if avatar_url = group_identity_picture_url(@group, @current_profile) do %>
            <img
              :if={!@group.is_root}
              src={avatar_url}
              alt={@group.name}
              class={[
                @avatar_size,
                "flex shrink-0 rounded-full border border-base-300 object-cover shadow-sm"
              ]}
            />
            <div
              :if={@group.is_root}
              class={[
                @avatar_size,
                "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
              ]}
            >
              <.icon name="hero-globe-alt" class="size-4" />
            </div>
          <% else %>
            <div class={[
              @avatar_size,
              "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
            ]}>
              <span :if={!@group.is_root}>{group_initials(@group.name)}</span>
              <.icon :if={@group.is_root} name="hero-globe-alt" class="size-4" />
            </div>
          <% end %>

          <div :if={!@group.is_direct && !@group.is_root} class="absolute bottom-0 left-0 -ml-1 -mb-1">
            {if @group.is_public,
              do: "📢",
              else: "🔐"}
          </div>

          <span
            :if={!@group.is_root and @pending_join_requests_count > 0}
            id={"group-pending-join-requests-badge-#{@group.id}"}
            class="absolute -left-2 -top-2 inline-flex min-w-5 items-center justify-center rounded-full bg-amber-500 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-amber-950 shadow-sm"
          >
            {unread_badge_label(@pending_join_requests_count)}
          </span>
          <span
            :if={!@group.is_root and @unread_count > 0}
            id={"group-unread-badge-#{@group.id}"}
            class="absolute -right-2 -top-2 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white shadow-sm"
          >
            {unread_badge_label(@unread_count)}
          </span>
        </div>

        <div
          :if={!@group.is_root}
          class="min-w-0 shrink"
        >
          <div class={[@text_class, "truncate font-semibold text-base-content"]}>
            {group_identity_name(@group, @current_profile)}
          </div>

          <div
            :if={false}
            class="mt-1 flex flex-wrap items-center gap-2 text-xs font-medium text-base-content/70"
          >
            <span
              id={"group-visibility-badge-#{@group.id}"}
              class={[
                "inline-flex items-center rounded-full px-2 py-1",
                if(@group.is_public,
                  do: "bg-emerald-100 text-emerald-700",
                  else: "bg-slate-200 text-slate-700"
                )
              ]}
            >
              {if @group.is_public, do: gettext("Public group"), else: gettext("Private group")}
            </span>
            <span
              id={"group-public-chat-badge-#{@group.id}"}
              class={[
                "inline-flex items-center rounded-full px-2 py-1",
                if(@group.has_public_chat,
                  do: "bg-sky-100 text-sky-700",
                  else: "bg-base-200 text-base-content/65"
                )
              ]}
            >
              {if @group.has_public_chat,
                do: gettext("Public chat enabled"),
                else: gettext("Public chat disabled")}
            </span>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  defp unread_badge_label(count) when count > 999, do: "999+"
  defp unread_badge_label(count), do: Integer.to_string(count)

  attr :content, :string, default: ""
  attr :content_format, :any, default: :markdown
  attr :class, :any, default: nil

  def formatted_content(assigns) do
    ~H"""
    <div class={[
      if(@content_format == :markdown,
        do:
          "px-4 break-words [&_a]:link [&_blockquote]:border-l-4 [&_blockquote]:border-base-300 [&_blockquote]:pl-4 [&_code]:rounded-md [&_code]:bg-base-300/70 [&_code]:px-1.5 [&_code]:py-0.5 [&_h1]:my-3 [&_h1]:text-2xl [&_h1]:font-semibold [&_h2]:my-3 [&_h2]:text-xl [&_h2]:font-semibold [&_h3]:my-2 [&_h3]:text-lg [&_h3]:font-semibold [&_ol]:list-decimal [&_ol]:pl-6 [&_p]:my-2 [&_pre]:overflow-x-auto [&_pre]:rounded-xl [&_pre]:bg-base-300/70 [&_pre]:p-3 [&_ul]:list-disc [&_ul]:pl-6",
        else: ""
      ),
      @class
    ]}>
      {render_formatted_content(%{content: @content, content_format: @content_format})}
    </div>
    """
  end

  attr :value, :map, required: true
  attr :dom_id, :string, required: true
  attr :current_profile, :map, default: nil
  attr :online_profile_ids, :any, required: true
  attr :expanded_value_ids, :any, required: true
  attr :editing_value_id, :integer, default: nil
  attr :edit_value_form, :any, default: nil

  def value_message(assigns) do
    mine? = value_from_current_profile?(assigns.current_profile, assigns.value)
    editing? = assigns.editing_value_id == assigns.value.id

    assigns =
      assigns
      |> assign(:mine?, mine?)
      |> assign(:editing?, editing?)
      |> assign(:avatar_url, profile_picture_url(assigns.value.creator))
      |> assign(
        :creator_online?,
        MapSet.member?(assigns.online_profile_ids, assigns.value.creator_id)
      )

    ~H"""
    <div id={@dom_id} class={["chat", (@mine? && "chat-end") || "chat-start"]}>
      <.inspect_tree
        :if={false}
        id={"value-message-assigns-#{@value.id}"}
        data={@value}
        label={"value#{@value.id}"}
        class="mb-3 w-full"
      />
      <%= if @avatar_url do %>
        <div class="chat-image avatar">
          <div class="relative size-10 rounded-full border border-base-300 shadow-sm">
            <img src={@avatar_url} alt={@value.creator.username} class="object-cover" />
          </div>

          <span
            :if={@creator_online?}
            id={"value-creator-presence-#{@value.id}"}
            class="absolute right-0 bottom-0 size-3 rounded-full border-2 border-base-100 bg-emerald-500"
            title={gettext("Online")}
          />
          <%!-- <span
            :if={@value.creator.sharing == :shared}
            class="absolute left-0 bottom-0 size-3 rounded-full border-2 border-base-100 bg-emerald-500"
          >👨‍👨‍👦‍👦</span> --%>
          <div class="absolute bottom-0 left-0 -ml-1 -mb-1">
            {if @value.creator.sharing == :shared,
              do: "👨‍👨‍👦‍👦",
              else: ""}
          </div>
        </div>
      <% else %>
        <div class="chat-image">
          <div class="relative flex size-10 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm">
            {profile_initials(@value.creator.username)}
            <span
              :if={@creator_online?}
              id={"value-creator-presence-#{@value.id}"}
              class="absolute right-0 bottom-0 size-3 rounded-full border-2 border-base-100 bg-emerald-500"
              title={gettext("Online")}
            />
          </div>
        </div>
      <% end %>

      <div class="chat-header mb-1 flex items-center gap-2 text-xs text-base-content/65">
        <span class="font-semibold text-base-content">{@value.creator.username}</span>
        <.local_time id={"value-inserted-at-#{@value.id}"} datetime={@value.inserted_at} />
        <span
          :if={@value.parent_id}
          class="rounded-full bg-base-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-[0.16em] text-base-content/45"
        >
          {gettext("reply")}
        </span>
        <div :if={@mine? and !@editing?} class="ml-auto flex items-center gap-1">
          <button
            id={"value-edit-#{@value.id}"}
            type="button"
            phx-click="start_edit_value"
            phx-value-id={@value.id}
            aria-label={gettext("Edit value")}
            class="inline-flex items-center rounded-full p-1 text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content"
          >
            <.icon name="hero-pencil-square" class="size-4" />
          </button>
          <button
            id={"value-delete-#{@value.id}"}
            type="button"
            phx-click="delete_value"
            phx-value-id={@value.id}
            aria-label={gettext("Delete value")}
            data-confirm={gettext("Are you sure you want to delete this value?")}
            class="inline-flex items-center rounded-full p-1 text-base-content/55 transition-colors hover:bg-base-300 hover:text-error"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>

      <div class={[
        "chat-bubble max-w-full rounded-3xl px-4 py-3 shadow-sm sm:max-w-[42rem]",
        @mine? && "chat-bubble-primary",
        !@mine? && "border border-base-300 bg-base-100 text-base-content",
        @editing? && "w-[80dvw]"
      ]}>
        <%= if @editing? do %>
          <.form
            for={@edit_value_form}
            id={"edit-value-form-#{@value.id}"}
            class="space-y-3"
            phx-change="validate_edit_value"
            phx-submit="save_edit_value"
          >
            <div
              id={"edit-value-editor-#{@value.id}"}
              phx-hook="MarkdownEditor"
              class="space-y-2"
              data-placeholder={gettext("Write your value in Markdown")}
            >
              <div
                id={"edit-value-editor-shell-#{@value.id}"}
                class="markdown-editor"
                phx-update="ignore"
              >
                <div
                  id={"edit-value-editor-surface-#{@value.id}"}
                  data-markdown-target="editor"
                  phx-update="ignore"
                >
                </div>
              </div>
               <textarea
                id={"edit-value-content-#{@value.id}"}
                name={@edit_value_form[:content].name}
                data-markdown-target="input"
                class="sr-only"
                aria-label={gettext("Value")}
              >{Phoenix.HTML.Form.normalize_value("textarea", @edit_value_form[:content].value)}</textarea>
              <p
                :for={error <- @edit_value_form[:content].errors}
                class="mt-1.5 flex items-center gap-2 text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="size-5" /> {translate_error(error)}
              </p>
            </div>

            <div class="flex justify-end gap-2">
              <.button type="submit" variant="primary">{gettext("Save changes")}</.button>
              <.button type="button" phx-click="cancel_edit_value">{gettext("Cancel")}</.button>
            </div>
          </.form>
        <% else %>
          <div class="relative">
            <div
              class={[
                !value_expanded?(@expanded_value_ids, @value) && value_expandable?(@value) &&
                  "overflow-hidden"
              ]}
              style={collapsed_value_style(@expanded_value_ids, @value)}
            >
              <.formatted_content content={@value.content} content_format={@value.content_format} />
            </div>

            <div
              :if={value_expandable?(@value) and !value_expanded?(@expanded_value_ids, @value)}
              class={[
                "pointer-events-none absolute inset-x-0 bottom-0 h-12 bg-gradient-to-t",
                @mine? && "from-primary to-transparent",
                !@mine? && "from-base-100 to-transparent"
              ]}
            >
            </div>

            <button
              :if={value_expandable?(@value)}
              type="button"
              phx-click="toggle_value_expansion"
              phx-value-id={@value.id}
              class={[
                "mt-3 text-sm font-semibold transition-opacity hover:opacity-80",
                @mine? && "text-primary-content",
                !@mine? && "text-primary"
              ]}
            >
              {if value_expanded?(@expanded_value_ids, @value),
                do: gettext("See less"),
                else: gettext("See more")}
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_formatted_content(%{content: content, content_format: :html}) do
    content
    ## TODO: sanitize properly while allowing basic formatting tags and links, maybe using HtmlSanitizeEx with a custom scrubber
    # |> sanitize_html()
    |> raw()
  end

  defp render_formatted_content(%{content: content, content_format: :markdown}) do
    content
    |> Earmark.as_html!(breaks: true)
    |> sanitize_html()
    |> raw()
  end

  defp render_formatted_content(%{content: content}) when is_binary(content), do: content

  defp sanitize_html(content) when is_binary(content), do: HtmlSanitizeEx.html5(content)

  defp datetime_to_iso8601(datetime) do
    datetime
    |> datetime_to_utc_datetime()
    |> DateTime.to_iso8601()
  end

  defp datetime_to_utc_datetime(%DateTime{} = datetime),
    do: DateTime.shift_zone!(datetime, "Etc/UTC")

  defp datetime_to_utc_datetime(%NaiveDateTime{} = datetime) do
    DateTime.from_naive!(datetime, "Etc/UTC")
  end

  defp value_expandable?(%{content: content}) when is_binary(content) do
    (String.contains?(content, "\n") and length(String.split(content, ~r/\R/, trim: false)) > 5) or
      String.length(content) > 320
  end

  defp value_expandable?(_), do: false

  defp value_expanded?(expanded_value_ids, %{id: value_id}) do
    MapSet.member?(expanded_value_ids, value_id)
  end

  defp collapsed_value_style(expanded_value_ids, value) do
    if value_expandable?(value) and !value_expanded?(expanded_value_ids, value) do
      "max-height: calc(1.5rem * 5);"
    else
      nil
    end
  end

  defp profile_picture_url(%{profile_picture_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  defp profile_picture_url(_), do: nil

  defp group_identity_picture_url(%{is_direct: true} = group, current_profile) do
    case direct_group_other_member(group, current_profile) do
      nil -> group_picture_url(group)
      profile -> profile_picture_url(profile) || group_picture_url(group)
    end
  end

  defp group_identity_picture_url(group, _current_profile), do: group_picture_url(group)

  defp group_identity_name(%{is_direct: true} = group, current_profile) do
    case direct_group_other_member(group, current_profile) do
      %{username: username} when is_binary(username) and username != "" -> username
      _ -> group.name
    end
  end

  defp group_identity_name(group, _current_profile), do: group.name

  defp group_picture_url(%{group_picture_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  defp group_picture_url(_), do: nil

  defp direct_group_other_member(%{members: members}, %{id: current_profile_id}) do
    if Ecto.assoc_loaded?(members) do
      Enum.find(members, &(&1.id != current_profile_id))
    else
      nil
    end
  end

  defp direct_group_other_member(_group, _current_profile), do: nil

  defp profile_initials(username) when is_binary(username) do
    username
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(fn part ->
      part
      |> String.first()
      |> to_string()
    end)
    |> case do
      "" -> "?"
      initials -> String.upcase(initials)
    end
  end

  defp profile_initials(_), do: "?"

  defp group_initials(name) when is_binary(name) do
    name
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(fn part ->
      part
      |> String.first()
      |> to_string()
    end)
    |> case do
      "" -> "?"
      initials -> String.upcase(initials)
    end
  end

  defp group_initials(_), do: "?"

  attr :label, :any, required: true
  attr :value, :any, required: true

  defp inspect_tree_node(assigns) do
    case classify_tree_value(assigns.value) do
      {:leaf, rendered_value} ->
        assigns = assign(assigns, :rendered_value, rendered_value)

        ~H"""
        <div class="flex items-start gap-2 leading-5">
          <span class="font-semibold text-primary/80">{format_tree_label(@label)}</span>
          <span class="break-all text-base-content/70">{@rendered_value}</span>
        </div>
        """

      {:container, kind, entries} ->
        assigns = assigns |> assign(:kind, kind) |> assign(:entries, entries)

        ~H"""
        <details open class="tree-node">
          <summary class="cursor-pointer select-none leading-5">
            <span class="font-semibold text-primary/80">{format_tree_label(@label)}</span>
            <span class="ml-2 text-base-content/55">{@kind}</span>
          </summary>

          <ul class="ml-3 mt-2 border-l border-base-300/70 pl-3">
            <li :for={{entry_label, entry_value} <- @entries} class="mt-2">
              <.inspect_tree_node label={entry_label} value={entry_value} />
            </li>
          </ul>
        </details>
        """
    end
  end

  defp classify_tree_value(value) when is_struct(value) do
    struct_name = value.__struct__ |> Module.split() |> List.last()

    {:container, "%#{struct_name}{}", value |> Map.from_struct() |> tree_map_entries()}
  end

  defp classify_tree_value(value) when is_map(value) do
    {:container, "%{}", tree_map_entries(value)}
  end

  defp classify_tree_value(value) when is_list(value) do
    {:container, "list(#{length(value)})",
     Enum.with_index(value) |> Enum.map(fn {item, index} -> {"[#{index}]", item} end)}
  end

  defp classify_tree_value(value) when is_tuple(value) do
    entries =
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> {"[#{index}]", item} end)

    {:container, "tuple(#{tuple_size(value)})", entries}
  end

  defp classify_tree_value(value) do
    {:leaf, inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)}
  end

  defp tree_map_entries(map) do
    map
    |> Enum.map(fn {key, value} -> {format_tree_key(key), value} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp format_tree_key(key) when is_atom(key), do: Atom.to_string(key)
  defp format_tree_key(key) when is_binary(key), do: inspect(key)
  defp format_tree_key(key), do: inspect(key)

  defp format_tree_label(label) when is_binary(label), do: label <> ":"
  defp format_tree_label(label), do: inspect(label) <> ":"

  defp value_from_current_profile?(%{id: current_profile_id}, %{creator_id: creator_id}) do
    current_profile_id == creator_id
  end

  defp value_from_current_profile?(_, _), do: false
end
