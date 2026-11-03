defmodule PotokIdeWeb.TagComponents do
  @moduledoc """
  Tag chips, the button that opens the tag editor and the editor itself
  (`PotokIdeWeb.TagEditor` keeps its state). Public tags show a `#`,
  private ones a lock; `hero-tag` already stands for custom roles.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Tags.Tag

  attr :id, :string, required: true
  attr :tags, :list, required: true
  attr :class, :any, default: nil
  attr :group_id, :integer, default: nil, doc: "keeps the tags page in this group"

  attr :size, :atom,
    default: :md,
    values: [:md, :sm],
    doc: "`:sm` keeps the chips on one line, shrinking them to the space there is"

  attr :max, :integer, default: nil, doc: "chips shown; a `+N` chip stands for the rest"

  def tag_chips(assigns) do
    {shown, hidden} =
      if assigns.max, do: Enum.split(assigns.tags, assigns.max), else: {assigns.tags, []}

    assigns = assign(assigns, shown: shown, hidden: hidden)

    ~H"""
    <div
      :if={@tags != []}
      id={@id}
      class={[
        "flex items-center gap-1",
        if(@size == :sm, do: "min-w-0 flex-nowrap", else: "flex-wrap"),
        @class
      ]}
    >
      <.link
        :for={tag <- @shown}
        id={"#{@id}-#{tag.id}"}
        navigate={tags_path([tag.id], @group_id)}
        title={tag_title(tag)}
        class={[
          "inline-flex items-center gap-0.5 rounded-full border font-medium leading-4 transition duration-150 ease-out hover:-translate-y-px active:scale-95",
          if(@size == :sm,
            do: "h-5 min-w-0 max-w-32 shrink px-1.5 text-[11px]",
            else: "h-6 max-w-48 px-2 text-xs"
          ),
          chip_class(tag)
        ]}
      >
        <.icon
          name={tag_icon(tag)}
          class={["shrink-0 opacity-70", if(@size == :sm, do: "size-2.5", else: "size-3")]}
        />
        <span class="truncate">{tag.name}</span>
      </.link>
      <span
        :if={@hidden != []}
        id={"#{@id}-more"}
        title={Enum.map_join(@hidden, ", ", & &1.name)}
        class={[
          "inline-flex shrink-0 items-center rounded-full border border-base-300 bg-base-100 font-semibold leading-none tabular-nums text-base-content/60",
          if(@size == :sm, do: "h-5 px-1.5 text-[11px]", else: "h-6 px-2 text-xs")
        ]}
      >
        +{length(@hidden)}
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :tags, :list, required: true
  attr :kind, :atom, required: true
  attr :item_id, :integer, required: true
  attr :class, :any, default: nil

  @doc "A `# N` chip for where the tags themselves don't fit; it opens the tag editor."
  def tag_count(assigns) do
    ~H"""
    <button
      :if={@tags != []}
      id={@id}
      type="button"
      phx-click="tag_editor_open"
      phx-value-kind={@kind}
      phx-value-id={@item_id}
      aria-haspopup="dialog"
      aria-label={gettext("Tags")}
      title={Enum.map_join(@tags, ", ", & &1.name)}
      class={[
        "inline-flex h-5 items-center gap-0.5 rounded-full border border-base-300 bg-base-200/70 px-1.5 text-[11px] font-semibold leading-4 tabular-nums text-base-content/75 transition duration-150 ease-out hover:bg-base-200 active:scale-95 phx-click-loading:animate-pulse",
        @class
      ]}
    >
      <.icon name="hero-hashtag" class="size-2.5 opacity-70" />
      {length(@tags)}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :kind, :atom, required: true
  attr :item_id, :integer, required: true
  attr :class, :any, default: nil
  attr :label, :string, default: nil

  def tag_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="tag_editor_open"
      phx-value-kind={@kind}
      phx-value-id={@item_id}
      aria-haspopup="dialog"
      aria-label={gettext("Tags")}
      title={gettext("Tags")}
      class={[
        "inline-flex items-center gap-1 rounded-full p-1 text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content phx-click-loading:animate-pulse",
        @class
      ]}
    >
      <.icon name="hero-hashtag" class="size-4" />
      <span :if={@label} class="pr-1 text-xs font-semibold">{@label}</span>
    </button>
    """
  end

  attr :editor, :map, default: nil, doc: "the `@tag_editor` assign of `PotokIdeWeb.TagEditor`"

  # A modal <dialog> sits in the top layer, above the nav bar, whatever the
  # stacking of the page around it. Patches keep the `open` the hook set.
  def tag_editor(assigns) do
    ~H"""
    <dialog
      :if={@editor}
      id="tag-editor"
      phx-hook=".TagEditorDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="tag-editor-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="tag-editor-backdrop"
          class="absolute inset-0 bg-base-content/30 backdrop-blur-[2px]"
          phx-click="tag_editor_close"
          aria-hidden="true"
        >
        </div>
        <section class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 sm:max-w-md sm:rounded-3xl">
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="mt-0.5 inline-flex size-9 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-hashtag" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id="tag-editor-title" class="text-base font-semibold leading-tight">
                {gettext("Tags")}
              </h2>
              <p id="tag-editor-item" class="mt-0.5 truncate text-sm text-base-content/60">
                {@editor.title}
              </p>
            </div>
            <button
              id="tag-editor-close"
              type="button"
              phx-click="tag_editor_close"
              aria-label={gettext("Close")}
              class="-mr-1 inline-flex size-8 shrink-0 items-center justify-center rounded-full text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </header>

          <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
            <ul id="tag-editor-tags" class="flex flex-wrap gap-1.5">
              <li
                :if={@editor.tags == []}
                id="tag-editor-empty"
                class="text-sm text-base-content/55"
              >
                {gettext("No tags yet.")}
              </li>
              <li
                :for={tag <- @editor.tags}
                id={"tag-editor-tag-#{tag.id}"}
                class={[
                  "inline-flex h-7 items-center gap-1 rounded-full border pl-2.5 text-sm font-medium",
                  if(removable?(tag, @editor), do: "pr-1", else: "pr-2.5"),
                  chip_class(tag)
                ]}
              >
                <.icon name={tag_icon(tag)} class="size-3.5 opacity-70" />
                <span class="max-w-56 truncate">{tag.name}</span>
                <button
                  :if={removable?(tag, @editor)}
                  id={"tag-editor-remove-#{tag.id}"}
                  type="button"
                  phx-click="tag_editor_remove"
                  phx-value-tag-id={tag.id}
                  aria-label={gettext("Remove tag %{name}", name: tag.name)}
                  class="inline-flex size-5 items-center justify-center rounded-full transition hover:bg-base-content/10"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </li>
            </ul>

            <.form
              for={@editor.form}
              id="tag-editor-form"
              phx-change="tag_editor_search"
              phx-submit="tag_editor_add"
              class="mt-4"
            >
              <div
                :if={@editor.can_public? and not @editor.public_only?}
                id="tag-editor-visibility"
                role="radiogroup"
                aria-label={gettext("Who sees the tag")}
                class="mb-3 grid grid-cols-2 gap-1 rounded-2xl border border-base-300 bg-base-200/60 p-1"
              >
                <label
                  :for={{visibility, icon, label} <- visibility_options()}
                  id={"tag-editor-visibility-#{visibility}"}
                  class={[
                    "flex cursor-pointer items-center justify-center gap-1.5 rounded-xl px-3 py-1.5 text-sm font-semibold transition",
                    if(@editor.form[:visibility].value == visibility,
                      do: "bg-base-100 text-base-content shadow-sm",
                      else: "text-base-content/60 hover:text-base-content"
                    )
                  ]}
                >
                  <input
                    type="radio"
                    name={@editor.form[:visibility].name}
                    value={visibility}
                    checked={@editor.form[:visibility].value == visibility}
                    class="sr-only"
                  />
                  <.icon name={icon} class="size-4" />
                  {label}
                </label>
              </div>
              <p
                :if={@editor.public_only?}
                id="tag-editor-public-note"
                class="mb-3 text-xs text-base-content/60"
              >
                {gettext("Everyone sees these tags on your profile.")}
              </p>
              <div class="flex items-start gap-2">
                <div class="min-w-0 flex-1">
                  <.input
                    field={@editor.form[:name]}
                    id="tag-editor-input"
                    type="text"
                    phx-debounce="200"
                    autocomplete="off"
                    maxlength={Tag.max_length()}
                    placeholder={gettext("New or existing tag")}
                    aria-label={gettext("Tag name")}
                    class="h-10 w-full rounded-full border border-base-300 bg-base-100 px-4 text-sm transition focus:border-primary/60 focus:outline-none focus:ring-2 focus:ring-primary/20"
                  />
                </div>
                <button
                  id="tag-editor-submit"
                  type="submit"
                  class="inline-flex h-10 shrink-0 items-center gap-1 rounded-full bg-primary px-4 text-sm font-semibold text-primary-content shadow-sm shadow-primary/30 transition hover:-translate-y-px hover:shadow-md active:scale-95 phx-submit-loading:animate-pulse"
                >
                  <.icon name="hero-plus" class="size-4" />
                  {gettext("Add")}
                </button>
              </div>
              <%!-- Shown here: the dialog covers the page's flash messages. --%>
              <p
                :if={@editor.error}
                id="tag-editor-error"
                role="alert"
                class="mb-2 flex items-start gap-1.5 px-1 text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                {@editor.error}
              </p>
            </.form>

            <div :if={@editor.suggestions != []} class="mt-1">
              <p class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/50">
                {gettext("Suggestions")}
              </p>
              <ul id="tag-editor-suggestions" class="flex flex-wrap gap-1.5">
                <li :for={{tag, index} <- Enum.with_index(@editor.suggestions)}>
                  <button
                    id={"tag-editor-suggestion-#{index}"}
                    type="button"
                    phx-click="tag_editor_add"
                    phx-value-name={tag.name}
                    phx-value-visibility={suggestion_visibility(tag, @editor)}
                    title={tag_title(tag)}
                    class={[
                      "inline-flex h-7 items-center gap-1 rounded-full border border-dashed px-2.5 text-sm transition duration-150 ease-out hover:-translate-y-px hover:border-solid active:scale-95",
                      chip_class(tag)
                    ]}
                  >
                    <.icon name="hero-plus" class="size-3.5 opacity-70" />
                    <span class="max-w-56 truncate">{tag.name}</span>
                    <.icon :if={!Tag.public?(tag)} name="hero-lock-closed" class="size-3 opacity-60" />
                  </button>
                </li>
              </ul>
            </div>
          </div>

          <footer class="flex items-center justify-between gap-3 border-t border-base-300/60 bg-base-200/40 px-5 py-3 text-xs text-base-content/60">
            <span class="inline-flex items-center gap-1">
              <.icon name="hero-lock-closed" class="size-3.5" />
              {gettext("Private tags are seen only by you.")}
            </span>
            <.link
              id="tag-editor-all-tags"
              navigate={~p"/tags"}
              class="shrink-0 font-semibold text-primary hover:underline"
            >
              {gettext("All tags")}
            </.link>
          </footer>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TagEditorDialog">
      export default {
        mounted() {
          // Escape closes the dialog through the server, which removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("tag_editor_close", {})
          })
          this.el.showModal()
        },
        updated() {
          if (!this.el.open) this.el.showModal()
        },
      }
    </script>
    """
  end

  @doc "The tags page showing the items with every tag in `tag_ids`."
  def tags_path(tag_ids, group_id \\ nil) do
    params =
      [t: Enum.join(tag_ids, ","), group: group_id]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    if params == [], do: ~p"/tags", else: ~p"/tags?#{params}"
  end

  defp visibility_options do
    [
      {"private", "hero-lock-closed", pgettext("tag visibility", "Private")},
      {"public", "hero-globe-alt", pgettext("tag visibility", "Public")}
    ]
  end

  defp removable?(%Tag{} = tag, editor), do: not Tag.public?(tag) or editor.can_public?

  # A public suggestion is added as public when the viewer may; otherwise a
  # private tag of the same name is made.
  defp suggestion_visibility(%Tag{} = tag, editor) do
    if Tag.public?(tag) and editor.can_public?, do: "public", else: "private"
  end

  def tag_icon(%Tag{} = tag),
    do: if(Tag.public?(tag), do: "hero-hashtag", else: "hero-lock-closed")

  def tag_title(%Tag{} = tag) do
    if Tag.public?(tag),
      do: gettext("Public tag %{name}", name: tag.name),
      else: gettext("Private tag %{name}, seen only by you", name: tag.name)
  end

  def chip_class(%Tag{} = tag) do
    if Tag.public?(tag),
      do: "border-primary/25 bg-primary/10 text-primary hover:bg-primary/15",
      else:
        "border-base-300 bg-base-200/70 text-base-content/75 hover:border-base-content/25 hover:bg-base-200"
  end
end
