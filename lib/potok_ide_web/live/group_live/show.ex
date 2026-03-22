defmodule PotokIdeWeb.GroupLive.Show do
  use PotokIdeWeb, :live_view

  import Phoenix.HTML, only: [raw: 1]

  alias PotokIde.Social
  alias PotokIde.Social.{Group, Value}
  alias PotokIdeWeb.ProfileAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100dvh-6rem)] flex-col sm:h-[calc(100dvh-6rem)] lg:h-[calc(100dvh-6rem)]">
        <div class="sticky top-[5.75rem] z-10 mb-2 rounded-[2rem] border border-base-300/70 bg-base-100/90 px-4 py-4 shadow-lg shadow-primary/5 backdrop-blur sm:px-5">
          <div class="flex items-center gap-3">
            <div :if={!@group.is_root and @group.parent_id} class="pt-1">
              <.link navigate={~p"/groups/#{@group.parent_id}"} class="link text-xl no-underline">
                {"❮"}
              </.link>
            </div>

            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-3">
                <.group_identity group={@group} avatar_size="size-14" text_class="text-lg" />
              </div>
            </div>
            <button
              id="group-subgroups-summary"
              type="button"
              phx-click="switch_tab"
              phx-value-tab="sub_groups"
              aria-label={gettext("Open sub-groups tab")}
              class="cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
            >
              <.icon
                name="hero-folder-open"
                class="size-6 shrink-0 rounded-full border p-1 shadow-sm"
              />
            </button>
            <button
              id="group-members-summary"
              type="button"
              phx-click="switch_tab"
              phx-value-tab="members"
              aria-label={gettext("Open members tab")}
              class="avatar-group -space-x-6 cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
            >
              <div :for={m <- @first3_members} class="avatar">
                <div class="bg-white w-8">
                  <img src={m.profile_picture_url} alt={m.username} />
                </div>
              </div>
              <div :if={@members_count > 3} class="avatar avatar-placeholder">
                <div class="bg-neutral text-neutral-content w-8">
                  <span>+{@members_count - length(@first3_members)}</span>
                </div>
              </div>
            </button>

            <Layouts.header_menu icon="hero-ellipsis-horizontal">
              <div class="flex min-w-[14rem] flex-col gap-2">
                <.group_tab_button
                  id="group-tab-values"
                  tab="values"
                  active_tab={@active_tab}
                  label={gettext("Values")}
                />
                <.group_tab_button
                  id="group-tab-sub-groups"
                  tab="sub_groups"
                  active_tab={@active_tab}
                  label={gettext("Sub-groups")}
                />
                <.group_tab_button
                  id="group-tab-members"
                  tab="members"
                  active_tab={@active_tab}
                  label={gettext("Members")}
                />
                <.group_tab_button
                  :if={@is_member}
                  id="group-tab-create-sub-group"
                  tab="create_group"
                  active_tab={@active_tab}
                  label={gettext("Create sub-group")}
                />
                <.group_tab_button
                  :if={@is_member}
                  id="group-tab-invite-profile"
                  tab="invite_profile"
                  active_tab={@active_tab}
                  label={gettext("Invite profile")}
                />
              </div>
            </Layouts.header_menu>
          </div>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto pr-1">
          <div class="flex min-h-0 flex-1 flex-col gap-2 pb-1">
            <div :if={!@is_member} class="alert">
              <.icon name="hero-lock-closed" class="size-5 shrink-0" />
              <div>
                {gettext(
                  "You can view this group, but you must be a member to post values, invite members, or create sub-groups."
                )}
              </div>
            </div>

            <div
              :if={@active_tab == "sub_groups"}
              id="group-panel-sub-groups"
              class="card bg-base-200"
            >
              <div class="card-body">
                <h3 class="card-title">{gettext("Sub-groups")}</h3>

                <div :if={@children == []} class="text-base-content/70">
                  {gettext("No sub-groups yet.")}
                </div>

                <ul :if={@children != []} class="space-y-2">
                  <li :for={g <- @children}>
                    <.link
                      navigate={~p"/groups/#{g.id}"}
                      class="block rounded-2xl px-2 py-2 transition-colors hover:bg-base-300/50"
                    >
                      <div class="flex items-center justify-between gap-3">
                        <.group_identity group={g} avatar_size="size-10" text_class="text-sm" />
                        <span class="text-xs text-base-content/60">
                          ({if g.is_public, do: gettext("public"), else: gettext("private")})
                        </span>
                      </div>
                    </.link>
                  </li>
                </ul>
              </div>
            </div>

            <div :if={@active_tab == "members"} id="group-panel-members" class="card bg-base-200">
              <div class="card-body">
                <h3 class="card-title">{gettext("Members")}</h3>

                <div :if={@members == []} class="text-base-content/70">{gettext("No members.")}</div>

                <ul :if={@members != []} class="space-y-2">
                  <li :for={m <- @members}>
                    <.profile_identity profile={m} />
                  </li>
                </ul>
              </div>
            </div>

            <div
              :if={@active_tab == "values"}
              id="group-panel-values"
              class="card flex min-h-0 flex-1 bg-base-200 shadow-sm"
            >
              <div class="flex min-h-0 flex-1 flex-col">
                <div
                  id="group-values-feed"
                  phx-hook=".ValuesFeed"
                  class="flex flex-1 flex-col rev gap-4 overflow-y-auto px-4 py-5 sm:px-6"
                >
                  <div
                    :if={@values == []}
                    class="flex h-full min-h-56 items-center justify-center rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/60"
                  >
                    {gettext("No values yet. Start the conversation below.")}
                  </div>

                  <.value_message
                    :for={v <- @values}
                    value={v}
                    current_profile={@current_profile}
                    expanded_value_ids={@expanded_value_ids}
                    editing_value_id={@editing_value_id}
                    edit_value_form={@edit_value_form}
                  />
                </div>

                <div class="flex flex-auto"></div>

                <div
                  :if={@is_member}
                  class="sticky bottom-0 z-10 border-t border-base-300/70 bg-base-100/95 px-4 py-4 shadow-[0_-12px_24px_rgba(0,0,0,0.08)] backdrop-blur sm:px-6"
                >
                  <.form
                    for={@new_value_form}
                    id="group-value-form"
                    class="rounded-[1.75rem] flex border border-base-300 bg-base-100 p-3 shadow-sm"
                    phx-change="validate_value"
                    phx-submit="create_value"
                  >
                    <.input
                      field={@new_value_form[:content]}
                      id="group-value-content"
                      aria-label={gettext("Value")}
                      class="min-h-24 w-full flex-auto overflow-hidden border-0 bg-transparent px-1 py-1 text-sm leading-6 text-base-content placeholder:text-base-content/40 focus:outline-none"
                      placeholder={gettext("Write a value...")}
                      rows="1"
                      type="textarea"
                      phx-hook=".SubmitOnEnter"
                      required
                    />

                    <%!-- <div class="flex flex-row flex-wrap items-center justify-between gap-3 border-t border-base-300/70 pt-3"> --%>
                    <%!-- <div class="flex min-w-0 flex-1 flex-row flex-wrap items-center gap-3"> --%>
                    <%!-- TODO:/ markdown/html reply... --%>
                    <%!-- <div class="w-full sm:w-auto sm:min-w-40">
                        <div
                          aria-label={gettext("Format")}
                          class="inline-flex rounded-full border border-base-300 bg-base-200 p-1 shadow-sm"
                          role="radiogroup"
                        >
                          <label
                            for="group-value-format-markdown"
                            class={[
                              "cursor-pointer rounded-full px-4 py-2 text-sm font-medium transition-colors",
                              if(selected_value_format(@new_value_form[:content_format].value) == "markdown",
                                do: "bg-base-100 text-base-content shadow-sm",
                                else: "text-base-content/60 hover:text-base-content"
                              )
                            ]}
                          >
                            <input
                              id="group-value-format-markdown"
                              type="radio"
                              name={@new_value_form[:content_format].name}
                              value="markdown"
                              checked={selected_value_format(@new_value_form[:content_format].value) == "markdown"}
                              class="sr-only"
                            />
                            {gettext("Markdown")}
                          </label>

                          <label
                            for="group-value-format-html"
                            class={[
                              "cursor-pointer rounded-full px-4 py-2 text-sm font-medium transition-colors",
                              if(selected_value_format(@new_value_form[:content_format].value) == "html",
                                do: "bg-base-100 text-base-content shadow-sm",
                                else: "text-base-content/60 hover:text-base-content"
                              )
                            ]}
                          >
                            <input
                              id="group-value-format-html"
                              type="radio"
                              name={@new_value_form[:content_format].name}
                              value="html"
                              checked={selected_value_format(@new_value_form[:content_format].value) == "html"}
                              class="sr-only"
                            />
                            {gettext("HTML")}
                          </label>
                        </div>
                      </div> --%>
                    <%!-- <p class="text-xs text-base-content/55">
                        {gettext("Press Enter to send. Use Shift+Enter for a new line.")}
                      </p> --%>
                    <%!-- <.input
                        field={@new_value_form[:parent_id]}
                        id="group-value-parent"
                        label={gettext("Reply to value")}
                        type="select"
                        prompt={gettext("(none)")}
                        options={@value_parent_options}
                      /> --%>
                    <%!-- </div> --%>

                    <.button
                      aria-label={gettext("Post value")}
                      class="btn btn-primary btn-circle size-12 flex-none"
                    >
                      <.icon name="hero-paper-airplane" class="size-4" />
                    </.button>
                    <%!-- </div> --%>
                  </.form>
                </div>

                <div
                  :if={!@is_member}
                  class="border-t border-base-300/70 bg-base-100/70 px-4 py-4 text-sm text-base-content/60 sm:px-6"
                >
                  {gettext("Join this group to reply and post new values.")}
                </div>

                <script :type={Phoenix.LiveView.ColocatedHook} name=".ValuesFeed">
                  export default {
                    mounted() {
                      this.pendingScroll = false

                      this.handleEvent("scroll_values_to_latest", () => {
                        this.pendingScroll = true
                      })
                    },

                    updated() {
                      requestAnimationFrame(() => {
                        this.scrollToLatest()
                        this.pendingScroll = false
                      })
                    },

                    scrollToLatest() {
                      if (this.el.classList.contains("flex-col rev")) {
                        console.log("Scrolling to top (flex-col rev)", this.el.scrollHeight)
                        this.el.scrollTop = this.el.scrollHeight
                        return
                      }
                      console.log("Scrolling to bottom this.el: ", this.el.scrollHeight)
                      this.el.scrollTop = this.el.scrollHeight
                    },
                  }
                </script>

                <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
                  export default {
                    mounted() {
                      this.handleInput = () => this.autoResize()
                      this.handleKeydown = (event) => {
                        if (event.key !== "Enter" || event.shiftKey || event.isComposing) {
                          return
                        }

                        event.preventDefault()
                        this.el.form?.requestSubmit()
                      }

                      this.el.addEventListener("input", this.handleInput)
                      this.el.addEventListener("keydown", this.handleKeydown)
                      this.autoResize()
                    },

                    updated() {
                      this.autoResize()
                    },

                    destroyed() {
                      this.el.removeEventListener("input", this.handleInput)
                      this.el.removeEventListener("keydown", this.handleKeydown)
                    },

                    autoResize() {
                      this.el.style.height = "auto"
                      this.el.style.height = `${this.el.scrollHeight}px`
                    },
                  }
                </script>
              </div>
            </div>

            <div
              :if={@is_member and @active_tab == "create_group"}
              id="group-panel-create-group"
              class="card bg-base-200"
            >
              <div class="card-body">
                <h3 class="card-title">{gettext("Create sub-group")}</h3>

                <.form for={@new_group_form} phx-change="validate_group" phx-submit="create_group">
                  <.input field={@new_group_form[:name]} label={gettext("Name")} required />
                  <.input
                    field={@new_group_form[:group_picture_url]}
                    label={gettext("Group picture URL")}
                    type="url"
                  />
                  <.input
                    field={@new_group_form[:description_format]}
                    label={gettext("Format")}
                    type="select"
                    options={@format_options}
                  />
                  <.input
                    field={@new_group_form[:description]}
                    label={gettext("Description")}
                    type="textarea"
                  />
                  <.input
                    field={@new_group_form[:is_public]}
                    label={gettext("Public")}
                    type="checkbox"
                  />
                  <.input
                    field={@new_group_form[:parent_value_id]}
                    label={gettext("Reply to value (optional)")}
                    type="select"
                    prompt={gettext("(none)")}
                    options={@value_parent_options}
                  />
                  <.button phx-disable-with={gettext("Creating...")} variant="primary">
                    {gettext("Create")}
                  </.button>
                </.form>
              </div>
            </div>

            <div
              :if={@is_member and @active_tab == "invite_profile"}
              id="group-panel-invite-profile"
              class="card bg-base-200"
            >
              <div class="card-body">
                <h3 class="card-title">{gettext("Invite profile")}</h3>

                <.form for={@invite_form} phx-submit="invite">
                  <.input
                    field={@invite_form[:username]}
                    label={gettext("Invitee username")}
                    required
                  />
                  <.button phx-disable-with={gettext("Inviting...")} variant="primary">
                    {gettext("Invite")}
                  </.button>
                </.form>

                <div class="mt-2 text-xs text-base-content/60">
                  {gettext("Invitees accept invitations at")}
                  <.link navigate={~p"/invitations"} class="link">/invitations</.link>.
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
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
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        "w-full rounded-2xl px-4 py-2 text-left text-sm font-medium transition-colors",
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

  attr :profile, :map, required: true
  attr :avatar_size, :string, default: "size-11"
  attr :text_class, :string, default: "text-sm"

  def profile_identity(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-3">
      <div class="relative">
        <%= if avatar_url = profile_picture_url(@profile) do %>
          <img
            src={avatar_url}
            alt={@profile.username}
            class={[@avatar_size, "shrink-0 rounded-full border border-base-300 object-cover shadow-sm"]}
          />
        <% else %>
          <div class={[
            @avatar_size,
            "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
          ]}>
            {profile_initials(@profile.username)}
          </div>
        <% end %>
        <div class="absolute bottom-0 left-0 -ml-1 -mb-1">
          <%!-- {if @group.is_public,
            do: raw("<div class='size-4 rounded-full bg-green-500 ring ring-green-500 ring-offset-1'></div>"),
            else: raw("<div class='size-4 rounded-full bg-gray-500 ring ring-gray-500 ring-offset-1'></div>")
          } --%>
          {if @profile.sharing == :shared,
            do: "👨‍👨‍👦‍👦",
            else: ""}
        </div>
      </div>

      <div class="min-w-0">
        <div class={[@text_class, "truncate font-semibold text-base-content"]}>
          {@profile.username}
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
    <div class="flex min-w-0 items-center gap-3">
      <div class="relative">
        <%= if avatar_url = group_picture_url(@group) do %>
          <img
            src={avatar_url}
            alt={@group.name}
            class={[
              @avatar_size,
              "shrink-0 rounded-full border border-base-300 object-cover shadow-sm"
            ]}
          />
        <% else %>
          <div class={[
            @avatar_size,
            "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
          ]}>
            {group_initials(@group.name)}
          </div>
        <% end %>
        <div class="absolute bottom-0 left-0 -ml-1 -mb-1">
          <%!-- {if @group.is_public,
            do: raw("<div class='size-4 rounded-full bg-green-500 ring ring-green-500 ring-offset-1'></div>"),
            else: raw("<div class='size-4 rounded-full bg-gray-500 ring ring-gray-500 ring-offset-1'></div>")
          } --%>
          {if @group.is_public,
            do: "📢",
            else: "🔐"}
        </div>
      </div>

      <div class="min-w-0">
        <div class={[@text_class, "truncate font-semibold text-base-content"]}>
          {@group.name}
        </div>
      </div>
    </div>
    """
  end

  attr :value, :map, required: true
  attr :current_profile, :map, default: nil
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

    ~H"""
    <div id={"value-#{@value.id}"} class={["chat", (@mine? && "chat-end") || "chat-start"]}>
      <div class="chat-image avatar">
        <%= if @avatar_url do %>
          <div class="size-10 rounded-full border border-base-300 shadow-sm">
            <img src={@avatar_url} alt={@value.creator.username} class="object-cover" />
          </div>
        <% else %>
          <div class="flex size-10 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm">
            {profile_initials(@value.creator.username)}
          </div>
        <% end %>
      </div>

      <div class="chat-header mb-1 flex items-center gap-2 text-xs text-base-content/65">
        <span class="font-semibold text-base-content">{@value.creator.username}</span>
        <time>{Calendar.strftime(@value.inserted_at, "%Y-%m-%d %H:%M")}</time>
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
              required
            />

            <div class="flex justify-end gap-2">
              <.button type="submit" variant="primary">
                {gettext("Save changes")}
              </.button>
              <.button type="button" phx-click="cancel_edit_value">
                {gettext("Cancel")}
              </.button>
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

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(id)

    is_member = Social.member_of_group?(current_profile, group)

    if can_view_group?(group, is_member) do
      if connected?(socket) do
        Social.subscribe_group(group)
      end

      {:ok,
       socket
       |> assign(:is_member, is_member)
       |> assign(:active_tab, default_active_tab())
       |> assign(:editing_value_id, nil)
       |> assign(:edit_value_form, nil)
       |> load_group_data(group)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that group."))
       |> push_navigate(to: ~p"/groups")}
    end
  end

  @impl true
  def handle_event("validate_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    attrs =
      attrs
      |> Map.put_new("creator_id", current_profile.id)
      |> Map.put_new("group_id", group.id)

    changeset =
      %Value{}
      |> Value.changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_value_form, to_form(changeset))}
  end

  def handle_event("create_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, gettext("You must be a group member to post values."))}
    else
      case Social.create_value(current_profile, group, normalize_select_nil(attrs, "parent_id")) do
        {:ok, _value} ->
          socket =
            socket
            |> assign(:active_tab, "values")
            |> put_flash(:info, gettext("Value posted."))
            |> refresh_group_data()
            |> push_event("scroll_values_to_latest", %{})

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_value_form, to_form(changeset))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create value."))}
      end
    end
  end

  def handle_event("start_edit_value", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile

    case find_value(socket.assigns.values, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value when value.creator_id != current_profile.id ->
        {:noreply, put_flash(socket, :error, gettext("You can only edit your own values."))}

      value ->
        {:noreply,
         socket
         |> assign(:editing_value_id, value.id)
         |> assign(:edit_value_form, to_form(Value.changeset(value, %{})))}
    end
  end

  def handle_event("validate_edit_value", %{"value" => attrs}, socket) do
    case current_editing_value(socket) do
      nil ->
        {:noreply, socket}

      value ->
        changeset =
          value
          |> Value.changeset(attrs)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :edit_value_form, to_form(changeset))}
    end
  end

  def handle_event("save_edit_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile

    case current_editing_value(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value ->
        case Social.update_value(current_profile, value, attrs) do
          {:ok, _updated_value} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Value updated."))
             |> refresh_group_data()
             |> clear_edit_value()}

          {:error, :not_value_creator} ->
            {:noreply, put_flash(socket, :error, gettext("You can only edit your own values."))}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket, :edit_value_form, to_form(Map.put(changeset, :action, :validate)))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update value."))}
        end
    end
  end

  def handle_event("cancel_edit_value", _params, socket) do
    {:noreply, clear_edit_value(socket)}
  end

  def handle_event("delete_value", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile

    case find_value(socket.assigns.values, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value ->
        case Social.delete_value(current_profile, value) do
          {:ok, _deleted_value} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Value deleted."))
             |> refresh_group_data()}

          {:error, :not_value_creator} ->
            {:noreply, put_flash(socket, :error, gettext("You can only delete your own values."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete value."))}
        end
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, normalize_active_tab(tab, socket.assigns.is_member))}
  end

  def handle_event("validate_group", %{"group" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    parent = socket.assigns.group

    attrs =
      attrs
      |> Map.put_new("creator_id", current_profile.id)
      |> Map.put_new("parent_id", parent.id)
      |> Map.put_new("is_root", false)

    changeset =
      %Group{}
      |> Group.changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_group_form, to_form(changeset))}
  end

  def handle_event("create_group", %{"group" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    parent = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply,
       put_flash(socket, :error, gettext("You must be a group member to create sub-groups."))}
    else
      attrs =
        attrs
        |> normalize_select_nil("parent_value_id")
        |> Map.put("is_root", false)

      case Social.create_group(current_profile, parent, attrs) do
        {:ok, child} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Group created."))
           |> push_navigate(to: ~p"/groups/#{child.id}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_group_form, to_form(changeset))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create group."))}
      end
    end
  end

  def handle_event("invite", %{"invite" => %{"username" => username}}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, gettext("You must be a member to invite."))}
    else
      username = String.trim(username || "")

      with false <- username == "",
           %{} = invitee <- Social.get_profile_by_username(username),
           {:ok, _inv} <- Social.invite_profile_to_group(current_profile, group, invitee) do
        {:noreply, put_flash(socket, :info, gettext("Invitation sent."))}
      else
        true ->
          {:noreply, put_flash(socket, :error, gettext("Username is required."))}

        nil ->
          {:noreply, put_flash(socket, :error, gettext("No profile found with that username."))}

        {:error, :inviter_not_a_member} ->
          {:noreply, put_flash(socket, :error, gettext("You must be a member to invite."))}

        {:error, :cannot_invite_self} ->
          {:noreply, put_flash(socket, :error, gettext("You cannot invite yourself."))}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, gettext("An invitation is already pending."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not send invitation."))}
      end
    end
  end

  def handle_event("toggle_value_expansion", %{"id" => id}, socket) do
    value_id = String.to_integer(id)

    expanded_value_ids =
      if MapSet.member?(socket.assigns.expanded_value_ids, value_id) do
        MapSet.delete(socket.assigns.expanded_value_ids, value_id)
      else
        MapSet.put(socket.assigns.expanded_value_ids, value_id)
      end

    {:noreply, assign(socket, :expanded_value_ids, expanded_value_ids)}
  end

  @impl true
  def handle_info({:group_updated, _group_id}, %{assigns: %{current_profile: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:group_updated, group_id}, socket) when socket.assigns.group.id == group_id do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(group_id)
    is_member = Social.member_of_group?(current_profile, group)

    if can_view_group?(group, is_member) do
      {:noreply,
       socket
       |> assign(:is_member, is_member)
       |> load_group_data(group)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You do not have access to that group."))
       |> push_navigate(to: ~p"/groups")}
    end
  end

  def handle_info({:group_updated, _group_id}, socket), do: {:noreply, socket}

  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id do
    ProfileAuth.handle_current_profile_change(
      socket,
      fn socket, current_profile ->
        group = Social.get_group!(socket.assigns.group.id)
        is_member = Social.member_of_group?(current_profile, group)

        if can_view_group?(group, is_member) do
          {:noreply,
           socket
           |> assign(:is_member, is_member)
           |> load_group_data(group)}
        else
          {:noreply,
           socket
           |> put_flash(:error, gettext("You do not have access to that group."))
           |> push_navigate(to: ~p"/groups")}
        end
      end,
      fn socket ->
        {:noreply, push_navigate(socket, to: ~p"/profiles")}
      end
    )
  end

  def handle_info({:account_profiles_updated, _account_id}, socket), do: {:noreply, socket}

  defp load_group_data(socket, group) do
    values = Social.list_group_values(group)
    value_ids = MapSet.new(Enum.map(values, & &1.id))

    expanded_value_ids =
      socket.assigns
      |> Map.get(:expanded_value_ids, MapSet.new())
      |> MapSet.intersection(value_ids)

    active_tab =
      normalize_active_tab(Map.get(socket.assigns, :active_tab), socket.assigns.is_member)

    socket
    |> assign(:group, group)
    |> assign(
      :children,
      Social.list_child_groups_for_profile(group, socket.assigns.current_profile)
    )
    |> assign(:members_count, Social.count_group_members(group))
    |> assign(:first3_members, Social.list_first3_group_members(group))
    |> assign(:members, Social.list_group_members(group))
    |> assign(:values, values)
    |> assign(:active_tab, active_tab)
    |> assign(:expanded_value_ids, expanded_value_ids)
    |> assign(:format_options, [{gettext("Markdown"), :markdown}, {gettext("HTML"), :html}])
    |> assign(:value_parent_options, value_parent_options(values))
    |> assign(:new_value_form, to_form(Value.changeset(%Value{}, %{})))
    |> assign(
      :new_group_form,
      to_form(Group.changeset(%Group{}, %{is_public: false, description_format: :markdown}))
    )
    |> assign(:invite_form, to_form(%{"username" => ""}, as: "invite"))
  end

  defp refresh_group_data(socket) do
    load_group_data(socket, socket.assigns.group)
  end

  defp current_editing_value(socket) do
    find_value(socket.assigns.values, socket.assigns.editing_value_id)
  end

  defp find_value(_values, nil), do: nil

  defp find_value(values, id) when is_integer(id) do
    Enum.find(values, &(&1.id == id))
  end

  defp find_value(values, id) when is_binary(id) do
    Enum.find(values, &(Integer.to_string(&1.id) == id))
  end

  defp clear_edit_value(socket) do
    socket
    |> assign(:editing_value_id, nil)
    |> assign(:edit_value_form, nil)
  end

  defp value_parent_options(values) do
    Enum.map(values, fn v ->
      label =
        v.content
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 80)

      {"#{v.creator.username}: #{label}", v.id}
    end)
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

  defp default_active_tab, do: "values"

  defp normalize_active_tab(tab, _is_member) when tab in ["values", "sub_groups", "members"],
    do: tab

  defp normalize_active_tab(tab, true)
       when tab in ["create_group", "invite_profile"],
       do: tab

  defp normalize_active_tab(_, _), do: default_active_tab()

  defp normalize_select_nil(attrs, key) when is_binary(key) do
    case Map.get(attrs, key) do
      "" -> Map.put(attrs, key, nil)
      _ -> attrs
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

  defp can_view_group?(group, is_member) do
    group.is_public or is_member
  end

  defp value_from_current_profile?(%{id: current_profile_id}, %{creator_id: creator_id}) do
    current_profile_id == creator_id
  end

  defp value_from_current_profile?(_, _), do: false
end
