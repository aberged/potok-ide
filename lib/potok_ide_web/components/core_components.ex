defmodule PotokIdeWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: PotokIdeWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices: a card like the app's own, dropped in under the top
  safe area. Info takes the theme's primary color (on guest pages the mark's
  blue, see `.flash-card` in app.css), errors the error color.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :auto_dismiss, :boolean, default: true, doc: "whether the flash should close automatically"
  attr :dismiss_after_ms, :integer, default: 2000, doc: "how long to wait before auto-dismissing"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide_flash("##{@id}")}
      phx-hook={@auto_dismiss && "AutoDismissFlash"}
      data-auto-dismiss-flash={if @auto_dismiss, do: "true", else: nil}
      data-dismiss-after-ms={if @auto_dismiss, do: @dismiss_after_ms, else: nil}
      role="alert"
      class="pointer-events-none fixed inset-x-0 top-[calc(var(--app-safe-area-top)+0.75rem)] z-1000 px-4"
      {@rest}
    >
      <div class={[
        "flash-card pointer-events-auto mx-auto flex w-full max-w-sm cursor-pointer items-start gap-3 rounded-2xl border bg-base-100/95 p-2.5 text-sm text-base-content shadow-xl backdrop-blur transition duration-150 ease-out hover:-translate-y-px",
        @kind == :info && "border-base-300/70 shadow-primary/10",
        @kind == :error && "border-error/30 shadow-error/10"
      ]}>
        <span class={[
          "flex size-9 shrink-0 items-center justify-center rounded-full",
          @kind == :info && "bg-primary/10 text-primary",
          @kind == :error && "bg-error/10 text-error"
        ]}>
          <.icon :if={@kind == :info} name="hero-information-circle" class="size-5" />
          <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5" />
        </span>
        <div class="min-w-0 flex-1 self-center break-words py-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class={@title && "text-base-content/70"}>{msg}</p>
        </div>
        <button type="button" class={icon_button_class("ghost", "sm")} aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Hides a flash by sliding it back up, where it came from.
  """
  def hide_flash(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0",
         "opacity-0 -translate-y-3"}
    )
  end

  # Shared by `button/1` and `icon_button/1`. Hover and press effects sit
  # behind `not-disabled:` (not `enabled:`, which links never match).
  @control_base "cursor-pointer transition duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 disabled:cursor-not-allowed disabled:opacity-50 phx-click-loading:opacity-70 phx-submit-loading:opacity-70"

  @doc """
  Renders a button with navigation support.

  `variant` picks the look and `size` the height. `class` is added after
  them, for layout only (width, margins, position); it never replaces the
  look, so every button in the app stays the same pill.

    * `primary` - the one main action of a form, dialog or bar
    * `secondary` - a neutral side action, e.g. "Load more" or "Reject"
    * `ghost` - "Cancel" or "Discard" next to a primary button
    * `soft` - a call to action that is not the form's submit
    * `success`, `warning`, `danger` - accept, risky and destructive actions
    * `landing`, `landing_quiet` - the guest pages' look (`lp-button`)

  ## Examples

      <.button>Load more</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"} variant="ghost" size="sm">Home</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled form type)

  attr :class, :any, default: nil, doc: "layout classes, added after the variant's"

  attr :variant, :string,
    default: "secondary",
    values: ~w(primary secondary ghost soft success warning danger landing landing_quiet)

  attr :size, :string, default: "md", values: ~w(sm md)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :class, [button_class(assigns.variant, assigns.size), assigns.class])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc """
  The classes of `button/1`, for an element that cannot be one, like the
  `<label>` of a file input.
  """
  def button_class(variant \\ "secondary", size \\ "md")

  # The guest pages keep the blues of the Potok mark (`lp-button` in app.css).
  def button_class("landing", _size), do: "lp-button justify-center"
  def button_class("landing_quiet", _size), do: "lp-button-quiet"

  def button_class(variant, size) do
    [
      "inline-flex items-center justify-center gap-1.5 whitespace-nowrap rounded-full font-semibold not-disabled:active:scale-[0.97]",
      @control_base,
      button_size(size),
      button_variant(variant)
    ]
  end

  defp button_size("sm"), do: "h-8 px-3.5 text-xs"
  defp button_size("md"), do: "h-10 px-5 text-sm"

  defp button_variant("primary"),
    do:
      "bg-primary text-primary-content shadow-sm shadow-primary/30 not-disabled:hover:-translate-y-px not-disabled:hover:shadow-md"

  defp button_variant("secondary"),
    do:
      "border border-base-300 bg-base-100 text-base-content not-disabled:hover:-translate-y-px not-disabled:hover:border-base-content/30 not-disabled:hover:bg-base-200"

  defp button_variant("ghost"),
    do:
      "text-base-content/70 not-disabled:hover:bg-base-content/10 not-disabled:hover:text-base-content"

  defp button_variant("soft"),
    do:
      "border border-primary/30 bg-primary/10 text-primary not-disabled:hover:-translate-y-px not-disabled:hover:bg-primary/15"

  defp button_variant("success"),
    do:
      "border border-emerald-500/40 bg-emerald-500/10 text-emerald-700 not-disabled:hover:-translate-y-px not-disabled:hover:bg-emerald-500/15 dark:text-emerald-300"

  defp button_variant("warning"),
    do:
      "border border-amber-500/30 bg-amber-500/10 text-amber-900 not-disabled:hover:-translate-y-px not-disabled:hover:bg-amber-500/15 dark:text-amber-200"

  defp button_variant("danger"),
    do:
      "border border-error/30 bg-error/10 text-error not-disabled:hover:-translate-y-px not-disabled:hover:bg-error/15"

  @doc """
  Renders a round button that shows only an icon, with navigation support.
  `label` names it for screen readers and as its tooltip.

  `ghost` is for actions in rows and toolbars, `danger` the same for
  deleting, `secondary` a framed button on its own, `primary` the main one.
  Add `relative` through `class` when the inner block holds a badge.

  ## Examples

      <.icon_button icon="hero-pencil-square" label={gettext("Edit")} phx-click="edit" />
      <.icon_button icon="hero-trash" label={gettext("Delete")} variant="danger" />
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :variant, :string, default: "ghost", values: ~w(ghost danger secondary primary)
  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :class, :any, default: nil, doc: "layout classes, added after the variant's"

  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled form type)

  slot :inner_block, doc: "extras next to the icon, like an unread badge"

  def icon_button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :class, [icon_button_class(assigns.variant, assigns.size), assigns.class])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} aria-label={@label} title={@label} {@rest}>
        <.icon name={@icon} class={icon_button_icon_size(@size)} />{render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} aria-label={@label} title={@label} {@rest}>
        <.icon name={@icon} class={icon_button_icon_size(@size)} />{render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  The classes of `icon_button/1`, for an element that cannot be one, like the
  `<label>` of a file input or of the drawer toggle.
  """
  def icon_button_class(variant \\ "ghost", size \\ "sm") do
    [
      "inline-flex shrink-0 items-center justify-center rounded-full not-disabled:active:scale-95",
      @control_base,
      icon_button_size(size),
      icon_button_variant(variant)
    ]
  end

  defp icon_button_size("xs"), do: "size-6"
  defp icon_button_size("sm"), do: "size-8"
  defp icon_button_size("md"), do: "size-10"
  defp icon_button_size("lg"), do: "size-14"

  defp icon_button_icon_size("md"), do: "size-5"
  defp icon_button_icon_size("lg"), do: "size-6"
  defp icon_button_icon_size(_size), do: "size-4"

  defp icon_button_variant("ghost"),
    do:
      "text-base-content/60 not-disabled:hover:bg-base-content/10 not-disabled:hover:text-base-content"

  defp icon_button_variant("danger"),
    do: "text-base-content/60 not-disabled:hover:bg-error/10 not-disabled:hover:text-error"

  defp icon_button_variant("secondary"),
    do:
      "border border-base-300 bg-base-100 text-base-content/70 shadow-xs not-disabled:hover:-translate-y-px not-disabled:hover:border-base-content/30 not-disabled:hover:text-base-content"

  defp icon_button_variant("primary"),
    do:
      "bg-primary text-primary-content shadow-sm shadow-primary/30 not-disabled:hover:-translate-y-px not-disabled:hover:shadow-md"

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "radio"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset flex-auto">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span> <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "password"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <div class="relative" data-password-field>
          <input
            type={@type}
            name={@name}
            id={@id}
            value={Phoenix.HTML.Form.normalize_value(@type, @value)}
            class={[
              @class || "w-full input pr-11",
              @errors != [] && (@error_class || "input-error")
            ]}
            {@rest}
          />
          <button
            type="button"
            class={[icon_button_class(), "absolute inset-y-0 right-1 my-auto"]}
            data-password-toggle
            data-show-label={gettext("Show password")}
            data-hide-label={gettext("Hide password")}
            aria-label={gettext("Show password")}
            aria-pressed="false"
          >
            <.icon name="hero-eye" class="size-5" data-password-show-icon />
            <.icon name="hero-eye-slash" class="hidden size-5" data-password-hide-icon />
          </button>
        </div>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" /> {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">{render_slot(@inner_block)}</h1>

        <p :if={@subtitle != []} class="text-sm text-base-content/70">{render_slot(@subtitle)}</p>
      </div>

      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  The title of a card on a settings-like page: an icon tile, the title and a
  line under it.
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :class, :any, default: nil

  def card_title(assigns) do
    ~H"""
    <div class={["flex min-w-0 items-start gap-3", @class]}>
      <span class="inline-flex size-9 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
        <.icon name={@icon} class="size-5" />
      </span>
      <div class="min-w-0">
        <h2 class="font-semibold leading-tight">{@title}</h2>
        <p class="mt-0.5 text-sm text-base-content/60">{@subtitle}</p>
      </div>
    </div>
    """
  end

  @doc """
  The scrolling body of a top-level page such as tags, invitations, requests
  and profiles: one centered column, so they are the same width on wide
  screens. `class` goes on the column. Those pages pass `full_width` to
  `Layouts.app`, so the scroll area, and its scrollbar, reach the window's
  edge. The top space is the column's, so a `sticky top-0` bar sticks flush
  to the scroll area's edge.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def page_container(assigns) do
    ~H"""
    <div
      id={@id}
      data-tab-scroll
      class="relative min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 pb-4"
    >
      <div class={["mx-auto w-full max-w-3xl pt-4", @class]}>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  The header of a top-level page such as tags, invitations, requests and
  profiles: an icon tile, the title and a line under it.
  """
  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions, doc: "controls at the header's end, such as a view switch"

  def page_header(assigns) do
    ~H"""
    <header id={@id} class={["mb-5 flex flex-wrap items-start gap-3", @class]}>
      <span class="inline-flex size-11 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary shadow-sm">
        <.icon name={@icon} class="size-6" />
      </span>
      <div class="min-w-0 flex-1 basis-48">
        <h1 class="text-xl font-semibold leading-tight">{render_slot(@inner_block)}</h1>
        <p :if={@subtitle != []} class="mt-0.5 text-sm text-base-content/60">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>

          <th :if={@action != []}><span class="sr-only">{gettext("Actions")}</span></th>
        </tr>
      </thead>

      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>

          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>

          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"
  attr :rest, :global

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} {@rest} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(PotokIdeWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(PotokIdeWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
