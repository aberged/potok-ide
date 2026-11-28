defmodule PotokIde.Social.SiteExampleTest do
  @moduledoc """
  The example site for production (`SiteExample`): made as the Sajt app makes
  a site, so the app opens it as its own, and taken away again.
  """
  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    Access,
    AppData,
    AppFiles,
    Group,
    ScheduledPublication,
    SiteDoc,
    SiteExample,
    ValueAttachment
  }

  alias PotokIdeWeb.PostTemplates.Picture

  @moduletag :imagemagick
  @moduletag timeout: 180_000

  # The pictures once for all the tests: drawing them takes a while.
  setup_all do
    dir = Path.join(System.tmp_dir!(), "site-example-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    for name <- SiteExample.Pictures.names(),
        do: {:ok, _path} = SiteExample.Pictures.draw(name, dir)

    %{dir: dir}
  end

  setup %{dir: dir} do
    {account, profile} = account_with_profile!("glas-potoka")
    {:ok, report} = SiteExample.create(account.email, nil, dir: dir)
    %{account: account, profile: profile, report: report, site: Repo.get!(Group, report.site)}
  end

  defp children(%Group{id: id}),
    do: Repo.all(from(g in Group, where: g.parent_id == ^id, order_by: g.id))

  defp split(description) do
    ["<!--potok-site " <> marker, rest] = String.split(description, "-->\n", parts: 2)
    html = String.replace(rest, ~r/^<meta name="description" content="[^"]*">/, "")
    {Jason.decode!(marker), html}
  end

  test "a public site in the root, open to guests, made by the account's profile",
       %{profile: profile, site: site, report: report} do
    root = Social.get_root_group!()

    assert site.parent_id == root.id
    assert site.creator_id == profile.id
    assert site.preset == :site and site.uses_api
    assert site.is_public and site.description_for_guests
    assert Access.admin?(profile, site)
    assert report.url =~ "/groups/#{site.id}"
  end

  test "four sections where only editors add groups, open to guests", %{site: site} do
    files = site |> AppData.get_config(nil) |> AppFiles.groups() |> Map.values()
    sections = site |> children() |> Enum.reject(&(&1.id in files))

    assert Enum.map(sections, & &1.name) == ["Stranice", "Vesti", "Kultura", "Sport"]

    for section <- sections do
      assert section.is_public and section.inherits_members and section.description_for_guests
      refute Access.everyone_can?(Access.for_profile(nil, section), :create_subgroups)
    end
  end

  test "articles and pages as the app writes them, published in the past, a draft and one that opens later",
       %{site: site, report: report} do
    items =
      site
      |> children()
      |> Enum.flat_map(&children/1)

    assert length(items) == report.articles
    assert report.articles == 17

    now = DateTime.utc_now()
    {drafts, published} = Enum.split_with(items, &Group.draft?/1)

    assert length(published) == 15
    assert Enum.all?(published, &(DateTime.compare(&1.published_at, now) == :lt))
    assert Enum.all?(published, &(&1.is_public and &1.description_for_guests))

    assert [_, _] = drafts
    assert Enum.all?(drafts, &(&1.inherit_role_keys == ["admin"] and is_nil(&1.published_at)))

    assert [scheduled] =
             Repo.all(
               from(s in ScheduledPublication, where: s.group_id in ^Enum.map(drafts, & &1.id))
             )

    assert DateTime.compare(scheduled.publish_at, now) == :gt
    assert scheduled.is_public

    for item <- items do
      {marker, html} = split(item.description)

      assert marker["v"] == 1 and marker["kind"] in ["article", "page"]

      assert marker["hash"] == SiteDoc.hash(html),
             "#{item.name}: the app would open HTML, not blocks"

      assert item.description_format == :html
    end
  end

  test "the pictures in articles are the app's own files, behind signed addresses",
       %{site: site, report: report} do
    config = AppData.get_config(site, nil)
    %{"public" => file_group_id} = AppFiles.groups(config)

    attachments = Repo.all(from(a in ValueAttachment, where: a.group_id == ^file_group_id))
    assert length(attachments) == report.pictures

    srcs =
      site
      |> children()
      |> Enum.flat_map(&children/1)
      |> Enum.flat_map(fn item ->
        Regex.scan(~r/<img src="([^"]+)"/, item.description, capture: :all_but_first)
      end)
      |> List.flatten()
      |> Enum.uniq()

    assert srcs != []

    ids = MapSet.new(attachments, & &1.id)

    for src <- srcs do
      assert [_, token] = Regex.run(~r{/pictures/([^/?#]+)$}, src)
      assert {:ok, id} = Picture.verify(token)
      assert id in ids
    end

    # Covers are the articles' own pictures.
    assert site
           |> children()
           |> Enum.flat_map(&children/1)
           |> Enum.filter(&(&1.name == "Nova rasveta u Ulici lipa"))
           |> Enum.map(
             &Repo.one(from(g in Group, where: g.id == ^&1.id, select: g.group_picture_url))
           )
           |> Enum.all?(&String.starts_with?(&1, "data:image/jpeg;base64,"))
  end

  test "the config is public and names only groups of the site", %{site: site} do
    config = AppData.get_config(site, nil)
    assert AppData.readable_config?(config, site)

    ids =
      site
      |> children()
      |> Enum.flat_map(&[&1 | children(&1)])
      |> MapSet.new(& &1.id)

    data = config.data
    assert data["theme"]["id"] == "novine"
    assert Enum.all?(data["sections"], &(&1["id"] in ids))

    targets =
      Enum.flat_map(data["menus"]["main"], &[&1 | &1["children"]]) ++ data["menus"]["footer"]

    for %{"target" => target} <- targets, target["type"] in ["section", "item"] do
      assert target["id"] in ids
    end

    hero = Enum.find(data["home"], &(&1["type"] == "hero"))
    assert hero["image"] =~ "/pictures/"
  end

  test "a second time it says the site is there", %{account: account} do
    assert SiteExample.create(account.email) == {:error, :exists}
  end

  test "an account without one, or another's profile, makes nothing", %{account: account} do
    {_other, _profile} = account_with_profile!("drugi-nalog")

    assert SiteExample.create("nobody@example.com") == {:error, :no_account}
    assert SiteExample.create(account.email, "drugi-nalog") == {:error, :username_taken}
    assert SiteExample.create(account.email, "nema-ga") == {:error, :no_profile}
  end

  test "remove/1 takes the whole site away, and nothing else", %{profile: profile, site: site} do
    other = group_with_members!(profile, [])
    ids = site |> children() |> Enum.flat_map(&[&1.id | Enum.map(children(&1), fn c -> c.id end)])

    assert {:ok, deleted, 0} = SiteExample.remove(site.id)
    assert deleted == length(ids) + 1
    refute Repo.exists?(from(g in Group, where: g.id in ^[site.id | ids]))
    assert Repo.get(Group, other.id)

    assert SiteExample.remove(site.id) == {:error, :not_found}
    assert SiteExample.remove(Social.get_root_group!().id) == {:error, :not_a_site}
  end
end
