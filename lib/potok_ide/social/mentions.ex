defmodule PotokIde.Social.Mentions do
  @moduledoc """
  `@name` mentions in chat values.

  A handle names a role of the group's effective manifest (only when the
  author may mention roles) or a member's username, matched case-insensitively.
  A role wins when a role and a username share a name. Text inside code spans
  and code blocks is never a mention.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Repo
  alias PotokIde.Social.{Access, Group, GroupMembership, Profile}

  # Same characters as usernames and role names; the lookbehind keeps e-mail
  # addresses (`ana@example.com`) and `@@` out.
  @handle_regex ~r/(?<![\p{L}\p{Nd}_.@-])@([\p{L}\p{Nd}_.-]+)/u
  @fenced_code_regex ~r/```.*?(```|\z)/su
  @inline_code_regex ~r/`[^`\n]*`/u
  @trailing_punctuation_regex ~r/[.\-]+$/u

  @doc """
  The candidate handles in `content`, lowercased. A handle ending in `.` or
  `-` also yields its trimmed form, so "thanks @ana." can reach "ana".
  """
  def extract(content), do: content |> tokens() |> List.flatten() |> Enum.uniq()

  # One list of variants per `@` token, most specific first.
  defp tokens(content) when is_binary(content) do
    @handle_regex
    |> Regex.scan(strip_code(content), capture: :all_but_first)
    |> Enum.map(fn [handle] -> handle_variants(handle) end)
  end

  defp tokens(_content), do: []

  defp strip_code(content) do
    content
    |> then(&Regex.replace(@fenced_code_regex, &1, " "))
    |> then(&Regex.replace(@inline_code_regex, &1, " "))
  end

  defp handle_variants(handle) do
    handle = String.downcase(handle)
    trimmed = Regex.replace(@trailing_punctuation_regex, handle, "")

    if trimmed in ["", handle], do: [handle], else: [handle, trimmed]
  end

  @doc """
  Resolves the mentions of `content` written by `author` in `group`.

  Returns `{mentions, profile_ids}`: the handles that resolved, as
  `%{"profiles" => [...], "roles" => [...]}` (empty lists left out), and the
  members they reach, without the author.
  """
  def resolve(content, %Profile{} = author, %Group{} = group) do
    case tokens(content) do
      [] -> {%{}, []}
      tokens -> resolve_tokens(tokens, author, group)
    end
  end

  defp resolve_tokens(tokens, %Profile{} = author, %Group{} = group) do
    handles = tokens |> List.flatten() |> Enum.uniq()
    access = Access.for_profile(author, group)

    roles_by_name =
      if Access.can?(access, :mention_roles) and access.manifest do
        Map.new(access.manifest.roles, &{String.downcase(&1.name), &1})
      else
        %{}
      end

    member_ids_by_name =
      from(p in Profile,
        join: gm in GroupMembership,
        on: gm.profile_id == p.id,
        where: gm.group_id == ^group.id and fragment("lower(?)", p.username) in ^handles,
        select: {fragment("lower(?)", p.username), p.id}
      )
      |> Repo.all()
      |> Map.new()

    {role_names, profile_names} =
      Enum.reduce(tokens, {[], []}, fn variants, {roles, profiles} ->
        Enum.find_value(variants, {roles, profiles}, fn handle ->
          cond do
            Map.has_key?(roles_by_name, handle) -> {[handle | roles], profiles}
            Map.has_key?(member_ids_by_name, handle) -> {roles, [handle | profiles]}
            true -> nil
          end
        end)
      end)

    role_profile_ids =
      Enum.flat_map(role_names, fn name ->
        Access.profile_ids_with_role(group, Map.fetch!(roles_by_name, name).key)
      end)

    profile_ids =
      profile_names
      |> Enum.map(&Map.fetch!(member_ids_by_name, &1))
      |> Enum.concat(role_profile_ids)
      |> Enum.reject(&(&1 == author.id))
      |> Enum.uniq()
      |> Enum.sort()

    mentions =
      [{"profiles", profile_names}, {"roles", role_names}]
      |> Enum.reject(fn {_kind, names} -> names == [] end)
      |> Map.new(fn {kind, names} -> {kind, names |> Enum.reverse() |> Enum.uniq()} end)

    {mentions, profile_ids}
  end

  @doc """
  Wraps the resolved mentions of sanitized `html` in
  `<span class="mention ..." data-mention="name">` elements. Only text outside
  `<code>`, `<pre>` and `<a>` elements is touched.
  """
  def highlight(html, mentions) when is_binary(html) and is_map(mentions) do
    profiles = mentions |> Map.get("profiles", []) |> MapSet.new()
    roles = mentions |> Map.get("roles", []) |> MapSet.new()

    if MapSet.size(profiles) == 0 and MapSet.size(roles) == 0 do
      html
    else
      ~r/(<[^>]*>)/
      |> Regex.split(html, include_captures: true)
      |> Enum.map_reduce(0, fn part, skip_depth ->
        cond do
          String.starts_with?(part, "<") -> {part, skip_depth + skip_delta(part)}
          skip_depth > 0 -> {part, skip_depth}
          true -> {highlight_text(part, profiles, roles), skip_depth}
        end
      end)
      |> elem(0)
      |> IO.iodata_to_binary()
    end
  end

  def highlight(html, _mentions), do: html

  defp skip_delta(tag) do
    case Regex.run(~r/^<(\/?)(code|pre|a)\b/i, tag) do
      [_, "", _name] -> 1
      [_, "/", _name] -> -1
      nil -> 0
    end
  end

  defp highlight_text(text, profiles, roles) do
    Regex.replace(@handle_regex, text, fn whole, handle ->
      trimmed = Regex.replace(@trailing_punctuation_regex, handle, "")

      [handle, trimmed]
      |> Enum.uniq()
      |> Enum.reject(&(&1 == ""))
      |> Enum.find_value(whole, fn candidate ->
        name = String.downcase(candidate)

        if kind = mention_kind(name, profiles, roles) do
          mention_span(kind, name, candidate) <> String.replace_prefix(handle, candidate, "")
        end
      end)
    end)
  end

  defp mention_kind(name, profiles, roles) do
    cond do
      MapSet.member?(roles, name) -> "role"
      MapSet.member?(profiles, name) -> "profile"
      true -> nil
    end
  end

  # Handles only contain letters, digits, `_`, `.` and `-`: safe in attributes.
  defp mention_span(kind, name, text) do
    ~s(<span class="mention mention-#{kind}" data-mention="#{name}">@#{text}</span>)
  end
end
