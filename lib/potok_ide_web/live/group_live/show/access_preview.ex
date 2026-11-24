defmodule PotokIdeWeb.GroupLive.Show.AccessPreview do
  @moduledoc """
  "See the group as": an admin of a group opens its page as roles picked
  together would see it, or as someone outside it, or a blocked profile
  (`?as=`). Only an admin, as an admin already sees whatever any role sees,
  so the preview cannot show anything hidden from the one who looks.

  Nothing changes while it lasts:

  - `guard/3`, a hook on every event of the page (it has no LiveComponents),
    lets through only what reads: tabs, lists, searches, closing dialogs;
  - uploads, which never pass through events, are refused where they start
    and where they end (`GroupLive.Show`);
  - the page writes no read marker, and the app of a description does not
    run, only its name shows.

  The preview is set at mount and lasts as long as the page: links within it
  keep it though they drop `?as=`, another `?as=` mounts the page anew, and
  leaving it mounts the page without one. It ends by itself when the one who
  looks stops being an admin, or the group no longer has what it showed.
  A guest's view is not a page of its own here: the overview tells it.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.Polls.Effects
  alias PotokIde.Social.{Access, Group, GroupRole}
  alias PotokIdeWeb.GroupLive.Show.AccessCatalog

  # Events that only read or move around the page.
  @reading ~w(
    switch_tab set_sub_groups_view switch_sub_groups_kind filter_children_preset
    filter_children_relation search_children clear_children_search clear_children_filters
    toggle_public_sub_groups toggle_thread_sub_groups toggle_sub_group_folder
    load_more_children load_more_sub_group_folders load_more_files load_more_members
    load_more_values load_newer_values jump_to_latest_values set_files_view search_files
    clear_files_search clear_files_filters filter_files_kind filter_members_role show_value
    group_row_menu_close group_sidebar_load group_sidebar_more group_sidebar_search
    clear_group_sidebar_search group_sidebar_toggle group_sidebar_sheet
    group_sidebar_sheet_close request_dialog_close request_decision_close group_sheet_close
    group_kind_close access_view_preset access_view_roles access_history_more
    access_preview_exit history_filter history_until history_actor history_actor_clear
    history_subject history_subject_clear history_more history_open history_close
    history_at history_thing history_records history_records_more history_record
  )

  @doc "The events a preview lets through."
  def reading_events, do: @reading

  @doc """
  The spec `param` asks for, when the holder of `real` may look at `group`
  so: an admin, in a group with roles to look through, and an outsider or a
  blocked profile only where the group is public. Unknown role keys are
  dropped; nil when nothing is left.
  """
  def parse(param, %Group{} = group, %Access{} = real) when is_binary(param) do
    if real.admin? and Effects.group_allowed?(group), do: spec(param, group, real.manifest)
  end

  def parse(_param, _group, _real), do: nil

  defp spec("outsider", %Group{is_public: true}, _manifest), do: :outsider
  defp spec("blocked", %Group{is_public: true}, _manifest), do: :blocked
  defp spec(kind, _group, _manifest) when kind in ["outsider", "blocked", "guest"], do: nil
  defp spec("everyone", _group, _manifest), do: {:member, []}

  defp spec(keys, _group, manifest) do
    known = MapSet.new(manifest.roles, & &1.key)

    keys
    |> String.split(",", trim: true)
    |> Enum.filter(&(MapSet.member?(known, &1) and &1 != GroupRole.everyone_key()))
    |> Enum.uniq()
    |> case do
      [] -> nil
      picked -> {:member, picked}
    end
  end

  @doc "The param that asks for `spec`, or nil for one no page is shown as."
  def param({:member, []}), do: "everyone"
  def param({:member, keys}), do: Enum.join(keys, ",")
  def param(kind) when kind in [:outsider, :blocked], do: Atom.to_string(kind)
  def param(_spec), do: nil

  @doc "What the page holds of a preview of `spec` under `manifest`."
  def state(spec, manifest),
    do: %{spec: spec, param: param(spec), label: AccessCatalog.spec_label(spec, manifest)}

  @doc "The access the page shows under the preview."
  def access(spec, manifest), do: AccessCatalog.viewer(manifest, spec).access

  @doc """
  The preview again, for the access the one who looks has now and the group
  as it is: `{:ok, state, access}`, or `:ended` when it no longer holds.
  """
  def reapply(%{param: param}, %Group{} = group, %Access{} = real) do
    case parse(param, group, real) do
      nil -> :ended
      spec -> {:ok, state(spec, real.manifest), access(spec, real.manifest)}
    end
  end

  @doc """
  The hook on the page's events while a preview lasts: what reads goes on,
  the rest stops with a word that nothing changes. A form's validation and
  suggestions stop quietly, as they come with every key.
  """
  def guard(event, _params, socket) do
    cond do
      event in @reading or String.starts_with?(event, "value_search_") ->
        {:cont, socket}

      String.starts_with?(event, "validate_") or event == "suggest_mentions" ->
        {:halt, %{}, socket}

      true ->
        {:halt, %{},
         Phoenix.LiveView.put_flash(
           socket,
           :info,
           gettext("This is only a preview of the group: nothing changes.")
         )}
    end
  end
end
