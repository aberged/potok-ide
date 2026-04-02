defmodule PotokIdeWeb.GroupLive.Show.Components do
  use PotokIdeWeb, :html

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

  def group_tab_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      data-dropdown-close
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        "w-full rounded-md px-4 py-2 text-left text-sm font-medium transition-colors",
        if(@active_tab == @tab,
          do: "bg-base-content text-base-100 shadow-sm",
          else: "bg-base-200 text-base-content/70 hover:bg-base-300 hover:text-base-content"
        )
      ]}
    >
      {@label}
    </button>
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
        <summary class="cursor-pointer select-none font-semibold text-base-content">
          {@label}
        </summary>
        <div class="mt-3 overflow-auto">
          <.inspect_tree_node label={@label} value={@data} />
        </div>
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

  def profile_identity(assigns) do
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

  attr :group, :map, required: true
  attr :avatar_size, :string, default: "size-11"
  attr :text_class, :string, default: "text-sm"

  def group_identity(assigns) do
    ~H"""
    <.link
      navigate={~p"/groups/#{@group.id}"}
      class="flex justify-start rounded-full w-full justify-items-start active:bg-base-200 hover:bg-base-100 pr-4"
    >
      <div class="flex min-w-0 items-center gap-3">
        <div class="relative">
          <%= if avatar_url = group_picture_url(@group) do %>
            <img
              :if={!@group.is_root}
              src={avatar_url}
              alt={@group.name}
              class={[
                @avatar_size,
                "shrink-0 rounded-full border border-base-300 object-cover shadow-sm"
              ]}
            />
            <div
              :if={@group.is_root}
              class={[
                @avatar_size,
                "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
              ]}
            >
              <.icon name="hero-home" class="size-4" />
            </div>
          <% else %>
            <div class={[
              @avatar_size,
              "flex shrink-0 items-center justif
              y-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
            ]}>
              <span :if={!@group.is_root}>{group_initials(@group.name)}</span>
              <.icon :if={@group.is_root} name="hero-home" class="size-4" />
            </div>
          <% end %>

          <div class="absolute bottom-0 left-0 -ml-1 -mb-1">
            {if @group.is_public,
              do: "📢",
              else: "🔐"}
          </div>
        </div>

        <div
          :if={!@group.is_root}
          class="min-w-0"
        >
          <div class={[@text_class, "truncate font-semibold text-base-content"]}>
            {@group.name}
          </div>
        </div>
      </div>
    </.link>
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
        !@mine? && "border border-base-300 bg-base-100 text-base-content"
      ]}>
        <%= if @editing? do %>
          <.form
            for={@edit_value_form}
            id={"edit-value-form-#{@value.id}"}
            class="space-y-3"
            phx-change="validate_edit_value"
            phx-submit="save_edit_value"
          >
            <.input
              field={@edit_value_form[:content]}
              id={"edit-value-content-#{@value.id}"}
              aria-label={gettext("Value")}
              type="textarea"
              rows="4"
              class="w-full textarea border-base-300 bg-base-100 text-base-content placeholder:text-base-content/40"
              required
            />
            <div class="flex justify-end gap-2">
              <.button type="submit" variant="primary">{gettext("Save changes")}</.button>
              <.button type="button" phx-click="cancel_edit_value">{gettext("Cancel")}</.button>
            </div>
          </.form>
        <% else %>
          <div class="relative">
            <div
              class={[
                "break-words [&_a]:link [&_blockquote]:border-l-4 [&_blockquote]:border-base-300 [&_blockquote]:pl-4 [&_code]:rounded-md [&_code]:bg-base-300/70 [&_code]:px-1.5 [&_code]:py-0.5 [&_h1]:my-3 [&_h1]:text-2xl [&_h1]:font-semibold [&_h2]:my-3 [&_h2]:text-xl [&_h2]:font-semibold [&_h3]:my-2 [&_h3]:text-lg [&_h3]:font-semibold [&_ol]:list-decimal [&_ol]:pl-6 [&_p]:my-2 [&_pre]:overflow-x-auto [&_pre]:rounded-xl [&_pre]:bg-base-300/70 [&_pre]:p-3 [&_ul]:list-disc [&_ul]:pl-6",
                !value_expanded?(@expanded_value_ids, @value) && value_expandable?(@value) &&
                  "overflow-hidden"
              ]}
              style={collapsed_value_style(@expanded_value_ids, @value)}
            >
              {render_value_content(@value)}
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

  defp render_value_content(%{content: content, content_format: :html}) do
    content
    |> sanitize_html()
    |> raw()
  end

  defp render_value_content(%{content: content, content_format: :markdown}) do
    content
    |> Earmark.as_html!(breaks: true)
    |> sanitize_html()
    |> raw()
  end

  defp render_value_content(%{content: content}) when is_binary(content), do: content

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

  defp group_picture_url(%{group_picture_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  defp group_picture_url(_), do: nil

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
