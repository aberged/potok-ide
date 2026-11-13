defmodule PotokIde.Social.LinkPreviewsTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.EventsFixtures
  alias PotokIde.LinkPreviews
  alias PotokIde.Social
  alias PotokIde.Social.Value

  # Answers every page with a title naming its path, and tells the test.
  setup do
    test_pid = self()

    Req.Test.stub(LinkPreviews, fn conn ->
      send(test_pid, {:fetched, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, """
      <html><head>
        <meta property="og:title" content="Page #{conn.request_path}">
        <meta property="og:image" content="https://cdn.example.com/card.png">
      </head></html>
      """)
    end)

    :ok
  end

  describe "create_value/4" do
    test "fetches the first link's preview and sends the value again" do
      owner = profile!("lp-owner")
      group = group!(owner, "lp-group")
      Social.subscribe_group(group)

      assert {:ok, value} =
               Social.create_value(owner, group, %{
                 "content" => "look https://example.com/one and https://example.com/two"
               })

      assert_received {:fetched, "/one"}
      refute_received {:fetched, "/two"}

      group_id = group.id
      value_id = value.id

      assert_received {:value_updated, ^group_id,
                       %Value{id: ^value_id, link_preview: %{"title" => "Page /one"}} = updated}

      assert updated.link_preview["image_url"] == "https://cdn.example.com/card.png"
      assert updated.link_preview["url"] == "https://example.com/one"
      assert %{"title" => "Page /one"} = Repo.get!(Value, value.id).link_preview
    end

    test "fetches nothing for a value without links" do
      owner = profile!("lp-nolink-owner")
      group = group!(owner, "lp-nolink-group")

      assert {:ok, value} = Social.create_value(owner, group, %{"content" => "just text"})

      refute_received {:fetched, _path}
      assert Repo.get!(Value, value.id).link_preview == nil
    end

    test "keeps no preview when the page cannot be read" do
      owner = profile!("lp-fail-owner")
      group = group!(owner, "lp-fail-group")
      Social.subscribe_group(group)

      Req.Test.stub(LinkPreviews, fn conn -> Plug.Conn.send_resp(conn, 500, "oops") end)

      assert {:ok, value} =
               Social.create_value(owner, group, %{"content" => "https://example.com/down"})

      refute_received {:value_updated, _group_id, _value}
      assert Repo.get!(Value, value.id).link_preview == nil
    end

    test "data values never get a preview" do
      owner = profile!("lp-data-owner")
      group = group!(owner, "lp-data-group")

      assert {:ok, value} =
               Social.create_value(owner, group, %{
                 "is_data" => true,
                 "content" => "https://example.com/data",
                 "data" => %{"a" => 1}
               })

      refute_received {:fetched, _path}
      assert Repo.get!(Value, value.id).link_preview == nil
    end
  end

  describe "a link to Potok" do
    setup do
      owner = profile!("lp-own-owner")
      %{owner: owner, group: group!(owner, "lp-own-group")}
    end

    defp own_url(path), do: PotokIdeWeb.Endpoint.url() <> path

    defp create_public_group!(owner, attrs) do
      {:ok, group} =
        Social.create_group(
          owner,
          Social.get_root_group!(),
          Map.merge(
            %{
              "description" => "Dogovaramo akcije.",
              "description_format" => :markdown,
              "is_public" => true
            },
            attrs
          )
        )

      group
    end

    test "to a public group shows the card a guest gets, with no request", ctx do
      linked = create_public_group!(ctx.owner, %{"name" => "Komšije"})
      url = own_url("/groups/#{linked.id}/values")

      assert {:ok, value} =
               Social.create_value(ctx.owner, ctx.group, %{"content" => "vidi #{url}"})

      assert %{
               "url" => ^url,
               "title" => "Komšije",
               "description" => "Dogovaramo akcije.",
               "site_name" => "Potok",
               "image_url" => image_url
             } = Repo.get!(Value, value.id).link_preview

      assert image_url =~ "/cards/group/#{linked.id}.jpg?v="
      refute_received {:fetched, _path}
    end

    # The address an app writes on the page (`linkGroup`), copied from the bar.
    test "to a story in an app shows the story, with the app's name", ctx do
      app = create_public_group!(ctx.owner, %{"name" => "Vesti", "home_page" => :description})

      {:ok, story} =
        Social.create_group(ctx.owner, app, %{
          "name" => "Most",
          "description" => "Most je otvoren.",
          "description_format" => :markdown,
          "is_public" => true
        })

      url = own_url("/groups/#{app.id}?at=#{story.id}")

      assert {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => url})

      assert %{
               "url" => ^url,
               "title" => "Most",
               "description" => "Most je otvoren.",
               "site_name" => "Vesti · Potok",
               "image_url" => image_url
             } = Repo.get!(Value, value.id).link_preview

      assert image_url =~ "/cards/group/#{app.id}/#{story.id}.jpg?v="
      refute_received {:fetched, _path}
    end

    test "to an event shows its card", ctx do
      linked = create_public_group!(ctx.owner, %{"name" => "Komšije"})

      event =
        EventsFixtures.create_event!(
          ctx.owner,
          linked,
          EventsFixtures.event_attrs(Date.add(EventsFixtures.today(), 3), %{
            "title" => "Čišćenje obale",
            "is_public" => "true"
          })
        )

      url = own_url("/groups/#{linked.id}/calendar?event=#{event.id}")

      assert {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => url})

      assert %{"title" => "Čišćenje obale", "image_url" => image_url} =
               Repo.get!(Value, value.id).link_preview

      assert image_url =~ "/cards/event/#{event.id}.jpg?v="
    end

    test "to a private group shows nothing of it", ctx do
      url = own_url("/groups/#{ctx.group.id}")

      assert {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => url})

      assert Repo.get!(Value, value.id).link_preview == nil
    end

    test "that has no card leaves its turn to the next link", ctx do
      url = own_url("/groups/#{ctx.group.id}")

      assert {:ok, value} =
               Social.create_value(ctx.owner, ctx.group, %{
                 "content" => "#{url} https://example.com/one"
               })

      assert %{"title" => "Page /one"} = Repo.get!(Value, value.id).link_preview
    end

    test "that is not a group is passed over", ctx do
      for path <- ["/", "/accounts/log-in", "/groups", "/files/1", "/groups/1/2/3"] do
        assert {:ok, value} =
                 Social.create_value(ctx.owner, ctx.group, %{"content" => own_url(path)})

        assert Repo.get!(Value, value.id).link_preview == nil
      end
    end

    test "with a query that cannot be decoded does not stop the message", ctx do
      linked = create_public_group!(ctx.owner, %{"name" => "Komšije"})

      for query <- ["x=%zz", "event=%ff", "at=%", "d=%ff&at=1"] do
        content = own_url("/groups/#{linked.id}/group_home?#{query}")

        assert {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => content})
        assert %{"title" => "Komšije"} = Repo.get!(Value, value.id).link_preview
      end
    end

    test "reads the same for everybody in the chat", ctx do
      linked = create_public_group!(ctx.owner, %{"name" => "Komšije", "description" => ""})
      url = own_url("/groups/#{linked.id}")

      Gettext.with_locale(PotokIdeWeb.Gettext, "en", fn ->
        assert {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => url})

        assert Repo.get!(Value, value.id).link_preview["description"] == "Grupa na Potoku."
      end)
    end
  end

  describe "update_value/3" do
    test "fetches again only when the first link changes" do
      owner = profile!("lp-edit-owner")
      group = group!(owner, "lp-edit-group")

      {:ok, value} = Social.create_value(owner, group, %{"content" => "https://example.com/a"})
      assert_received {:fetched, "/a"}

      {:ok, value} =
        Social.update_value(owner, value, %{"content" => "now: https://example.com/a"})

      refute_received {:fetched, _path}
      assert value.link_preview["title"] == "Page /a"

      {:ok, _value} = Social.update_value(owner, value, %{"content" => "https://example.com/b"})
      assert_received {:fetched, "/b"}
      assert %{"title" => "Page /b"} = Repo.get!(Value, value.id).link_preview

      {:ok, value} = Social.update_value(owner, value, %{"content" => "no link anymore"})
      assert value.link_preview == nil
    end

    test "an edit of a value read before its preview came drops the old link's preview" do
      owner = profile!("lp-stale-owner")
      group = group!(owner, "lp-stale-group")

      # `value` is the struct from before the preview was written.
      {:ok, value} = Social.create_value(owner, group, %{"content" => "https://example.com/old"})
      assert value.link_preview == nil
      assert %{"title" => "Page /old"} = Repo.get!(Value, value.id).link_preview

      Req.Test.stub(LinkPreviews, fn conn -> Plug.Conn.send_resp(conn, 500, "oops") end)

      {:ok, updated} =
        Social.update_value(owner, value, %{"content" => "https://example.com/new"})

      assert updated.link_preview == nil
      assert Repo.get!(Value, value.id).link_preview == nil
    end
  end

  describe "dismiss_value_link_preview/2" do
    test "the author removes the preview for good" do
      owner = profile!("lp-dismiss-owner")
      group = group!(owner, "lp-dismiss-group")
      Social.subscribe_group(group)

      {:ok, value} = Social.create_value(owner, group, %{"content" => "https://example.com/x"})
      assert_received {:fetched, "/x"}

      assert {:ok, %Value{link_preview: nil, link_preview_dismissed: true} = dismissed} =
               Social.dismiss_value_link_preview(owner, value)

      value_id = value.id
      assert_received {:value_updated, _group_id, %Value{id: ^value_id, link_preview: nil}}

      {:ok, _value} =
        Social.update_value(owner, dismissed, %{"content" => "https://example.com/y"})

      refute_received {:fetched, _path}
      assert %Value{link_preview: nil, link_preview_dismissed: true} = Repo.get!(Value, value.id)
    end

    test "other members cannot remove it" do
      owner = profile!("lp-other-owner")
      member = profile!("lp-other-member")
      group = group!(owner, "lp-other-group")
      add_member!(owner, group, member)

      {:ok, value} = Social.create_value(owner, group, %{"content" => "https://example.com/z"})

      assert {:error, :not_value_creator} = Social.dismiss_value_link_preview(member, value)
      assert %{"title" => "Page /z"} = Repo.get!(Value, value.id).link_preview
    end
  end

  defp profile!(username) do
    {:ok, profile} =
      Social.create_profile_for_account(account_fixture(), %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    profile
  end

  defp group!(owner, name) do
    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => name,
        "description" => "",
        "description_format" => :markdown
      })

    group
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
