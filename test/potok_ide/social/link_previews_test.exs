defmodule PotokIde.Social.LinkPreviewsTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.EventsFixtures
  alias PotokIde.LinkPreviews
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, Value}

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

  describe "a link to a form" do
    setup do
      owner = profile!("lp-form-owner")
      %{owner: owner, group: group!(owner, "lp-form-chat")}
    end

    defp form_url(form, path \\ ""), do: PotokIdeWeb.Endpoint.url() <> "/groups/#{form.id}#{path}"

    defp form!(owner, name, public? \\ false) do
      {:ok, %{group: form}} =
        Social.create_group_from_preset(owner, Social.get_root_group!(), "questionnaire", %{
          "name" => name,
          "is_public" => public?,
          "inherits_members" => false
        })

      form
    end

    defp form_config!(owner, form, form_data, rules \\ %{"responses" => %{}}) do
      {:ok, _config} =
        AppData.save_config(owner, form, nil, %{"form" => form_data, "rules" => rules}, 0)

      :ok
    end

    defp preview_of(%Value{id: id}), do: Repo.get!(Value, id).link_preview

    test "to a closed form shows its own title and subtitle, for its members alone", ctx do
      form = form!(ctx.owner, "Prijave")

      form_config!(ctx.owner, form, %{
        "title" => "**Prijava** za *izlet*",
        "description" => "Popuni do petka.\n- ime\n- broj mesta"
      })

      url = form_url(form, "/group_home")

      assert {:ok, value} =
               Social.create_value(ctx.owner, ctx.group, %{"content" => "vidi #{url}"})

      form_id = form.id

      assert %{
               "url" => ^url,
               "kind" => "questionnaire",
               "group_id" => ^form_id,
               "title" => "Prijava za izlet",
               "description" => "Popuni do petka. ime broj mesta",
               "image_url" => image_url,
               "open" => false
             } = preview = preview_of(value)

      assert image_url =~ "/avatar/group/#{form.id}?"
      assert image_url =~ "s="
      refute Map.has_key?(preview, "guest")
      refute_received {:fetched, _path}

      assert LinkPreviews.visible(preview, true) == preview
      assert LinkPreviews.visible(preview, false) == nil
      assert LinkPreviews.members_only_group_id(preview) == form.id
    end

    test "to a public form anyone fills in shows its card to everybody", ctx do
      form = form!(ctx.owner, "Anketa", true)

      form_config!(ctx.owner, form, %{"title" => "Anketa o parku"}, %{
        "responses" => %{"public" => true}
      })

      assert {:ok, value} =
               Social.create_value(ctx.owner, ctx.group, %{"content" => form_url(form)})

      assert %{"title" => "Anketa o parku", "description" => nil, "open" => true} =
               preview = preview_of(value)

      assert LinkPreviews.members_only_group_id(preview) == nil
      assert LinkPreviews.visible(preview, false) == preview
    end

    test "to a public form for members leaves the others the card a guest gets", ctx do
      form = form!(ctx.owner, "Članarina", true)
      form_config!(ctx.owner, form, %{"title" => "Članarina za 2027."})

      assert {:ok, value} =
               Social.create_value(ctx.owner, ctx.group, %{"content" => form_url(form)})

      assert %{"title" => "Članarina za 2027.", "open" => false, "guest" => guest} =
               preview = preview_of(value)

      assert %{"title" => "Članarina", "site_name" => "Potok"} = guest
      refute Map.has_key?(guest, "group_id")
      assert LinkPreviews.visible(preview, false) == guest
    end

    test "to a form nobody opened yet is named by its group", ctx do
      form = form!(ctx.owner, "Nova   forma")

      assert {:ok, value} =
               Social.create_value(ctx.owner, ctx.group, %{"content" => form_url(form)})

      assert %{"title" => "Nova forma", "description" => nil, "open" => false} = preview_of(value)
    end

    test "into an app, or to a group that is no form, is not a form's", ctx do
      form = form!(ctx.owner, "Prijave")
      form_config!(ctx.owner, form, %{"title" => "Prijava"})

      assert {:ok, value} =
               Social.create_value(ctx.owner, ctx.group, %{"content" => form_url(form, "?at=1")})

      assert preview_of(value) == nil

      {:ok, %{group: chat}} =
        Social.create_group_from_preset(ctx.owner, Social.get_root_group!(), "chat", %{
          "name" => "Dogovor"
        })

      assert {:ok, value} =
               Social.create_value(ctx.owner, ctx.group, %{"content" => form_url(chat)})

      assert preview_of(value) == nil
    end

    # A notice reaches followers no page asks about, so it takes only a card
    # any reader may see, and a closed form's link leaves its turn to the next.
    test "outside a chat gets only a card anyone may see", ctx do
      closed = form!(ctx.owner, "Prijave")
      open = form!(ctx.owner, "Anketa", true)
      form_config!(ctx.owner, open, %{"title" => "Anketa"}, %{"responses" => %{"public" => true}})

      assert LinkPreviews.fetch(form_url(closed)) == :error

      assert {:ok, %{"group_id" => _id}} =
               LinkPreviews.fetch(form_url(closed), closed_forms: true)

      assert {:ok, %{"open" => true}} = LinkPreviews.fetch(form_url(open))

      content = "#{form_url(closed)} https://example.com/next"
      assert LinkPreviews.first_url(content) == "https://example.com/next"
      assert LinkPreviews.first_url(content, closed_forms: true) == form_url(closed)
    end
  end

  describe "a link to a message" do
    setup do
      owner = profile!("lp-msg-owner")
      source = group!(owner, "lp-msg-source")

      {:ok, message} =
        Social.create_value(owner, source, %{"content" => "Tajni dogovor za subotu"})

      %{owner: owner, source: source, message: message, chat: group!(owner, "lp-msg-chat")}
    end

    defp message_url(group_id, value_id, path \\ "/values"),
      do: PotokIdeWeb.Endpoint.url() <> "/groups/#{group_id}#{path}?value=#{value_id}"

    defp preview_in!(owner, chat, content) do
      {:ok, value} = Social.create_value(owner, chat, %{"content" => content})
      Repo.get!(Value, value.id).link_preview
    end

    test "keeps which message it names and none of its text", ctx do
      url = message_url(ctx.source.id, ctx.message.id)
      source_id = ctx.source.id
      message_id = ctx.message.id

      assert %{
               "url" => ^url,
               "kind" => "message",
               "group_id" => ^source_id,
               "value_id" => ^message_id
             } = preview = preview_in!(ctx.owner, ctx.chat, "vidi #{url}")

      refute inspect(preview) =~ "Tajni"
      refute inspect(preview) =~ "lp-msg"
      refute Map.has_key?(preview, "guest")
      refute_received {:fetched, _path}

      # Nothing of it shows as a card by itself: the page draws the message.
      assert LinkPreviews.visible(preview, true) == nil
      assert LinkPreviews.members_only_group_id(preview) == nil
    end

    test "with no tab names the message too", ctx do
      url = message_url(ctx.source.id, ctx.message.id, "")

      assert %{"kind" => "message"} = preview_in!(ctx.owner, ctx.chat, url)
    end

    test "in a public group carries the card a guest gets of the group", ctx do
      {:ok, public} =
        Social.create_group(ctx.owner, Social.get_root_group!(), %{
          "name" => "Komšije",
          "description" => "Dogovaramo akcije.",
          "description_format" => :markdown,
          "is_public" => true
        })

      {:ok, message} = Social.create_value(ctx.owner, public, %{"content" => "Samo za članove"})

      assert %{"kind" => "message", "guest" => guest} =
               preview = preview_in!(ctx.owner, ctx.chat, message_url(public.id, message.id))

      assert %{"title" => "Komšije", "site_name" => "Potok"} = guest
      refute inspect(preview) =~ "Samo za članove"
      assert LinkPreviews.visible(preview, true) == guest
    end

    test "in a form's chat is the message's, not the form's", ctx do
      {:ok, %{group: form}} =
        Social.create_group_from_preset(ctx.owner, Social.get_root_group!(), "questionnaire", %{
          "name" => "Prijave",
          "inherits_members" => false
        })

      {:ok, message} = Social.create_value(ctx.owner, form, %{"content" => "Pitanje o formi"})

      assert %{"kind" => "message"} =
               preview_in!(ctx.owner, ctx.chat, message_url(form.id, message.id))
    end

    test "that names no chat message of that group is passed over", ctx do
      {:ok, data} =
        Social.create_value(ctx.owner, ctx.source, %{
          "is_data" => true,
          "content" => "data",
          "data" => %{"a" => 1}
        })

      for url <- [
            message_url(ctx.chat.id, ctx.message.id),
            message_url(ctx.source.id, data.id),
            message_url(ctx.source.id, ctx.message.id + 1_000_000),
            message_url(ctx.source.id, ctx.message.id, "/files"),
            message_url(ctx.source.id, "x"),
            PotokIdeWeb.Endpoint.url() <> "/groups/#{ctx.source.id}/values?value=%zz"
          ] do
        assert preview_in!(ctx.owner, ctx.chat, url) == nil, url
      end
    end

    # A notice reaches followers no page asks about: there the link stays as
    # it was, the card a guest gets of a public group or none.
    test "outside a chat names no message", ctx do
      url = message_url(ctx.source.id, ctx.message.id)

      assert LinkPreviews.fetch(url) == :error

      assert LinkPreviews.first_url("#{url} https://example.com/next") ==
               "https://example.com/next"

      assert {:ok, %{"kind" => "message"}} = LinkPreviews.fetch(url, message_links: true)
    end
  end

  describe "readable_linked_values/2" do
    setup do
      owner = profile!("rl-owner")
      member = profile!("rl-member")
      stranger = profile!("rl-stranger")
      group = group!(owner, "rl-group")
      add_member!(owner, group, member)

      {:ok, message} = Social.create_value(owner, group, %{"content" => "Za članove"})

      %{owner: owner, member: member, stranger: stranger, group: group, message: message}
    end

    defp reads(profile, %Value{id: id}) do
      case Social.readable_linked_values(profile, [id]) do
        %{^id => {%Value{id: ^id}, picture?}} -> {:reads, picture?}
        map when map == %{} -> :nothing
      end
    end

    test "a member reads a message of the group, with its pictures, others do not", ctx do
      assert reads(ctx.member, ctx.message) == {:reads, true}
      assert reads(ctx.stranger, ctx.message) == :nothing
      assert Social.readable_linked_values(nil, [ctx.message.id]) == %{}
      assert Social.readable_linked_values(ctx.member, []) == %{}
    end

    test "comes with the author, the group and the files", ctx do
      %{} = map = Social.readable_linked_values(ctx.member, [ctx.message.id])
      {value, true} = map[ctx.message.id]

      assert value.creator.id == ctx.owner.id
      assert value.group.id == ctx.group.id
      assert value.attachments == []
    end

    test "anyone reads an open chat, but for an event that is not public", ctx do
      open =
        create_group_with!(ctx.owner, "rl-open", %{"is_public" => true, "has_public_chat" => true})

      {:ok, message} = Social.create_value(ctx.owner, open, %{"content" => "Otvoreno"})
      assert reads(ctx.stranger, message) == {:reads, true}

      event =
        EventsFixtures.create_event!(
          ctx.owner,
          open,
          EventsFixtures.event_attrs(Date.add(EventsFixtures.today(), 3), %{
            "title" => "Sastanak članova"
          }),
          announce: true
        )

      announcement = Repo.get!(Value, event.value_id)
      assert reads(ctx.stranger, announcement) == :nothing
      assert reads(ctx.owner, announcement) == {:reads, true}
    end

    test "a public group with a closed chat is read by its members alone", ctx do
      public = create_group_with!(ctx.owner, "rl-public", %{"is_public" => true})
      {:ok, message} = Social.create_value(ctx.owner, public, %{"content" => "Zatvoreno"})

      assert reads(ctx.stranger, message) == :nothing
    end

    test "the group's members read its threads, but get their pictures only in them", ctx do
      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, ctx.message, %{"name" => "nit"})

      {:ok, reply} = Social.create_value(ctx.owner, thread, %{"content" => "U niti"})

      assert reads(ctx.owner, reply) == {:reads, true}
      assert reads(ctx.member, reply) == {:reads, false}
      assert reads(ctx.stranger, reply) == :nothing
    end

    test "a direct conversation is read by its two alone, named for the reader", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
      {:ok, message} = Social.create_value(ctx.owner, direct, %{"content" => "Samo nas dvoje"})

      assert reads(ctx.member, message) == {:reads, true}
      assert reads(ctx.stranger, message) == :nothing

      %{} = map = Social.readable_linked_values(ctx.member, [message.id])
      {value, true} = map[message.id]

      assert PotokIdeWeb.MessageLinks.card(value, true, ctx.member).group_name == "rl-owner"
    end

    test "a deleted message and an app's data value are read by nobody", ctx do
      {:ok, data} =
        Social.create_value(ctx.owner, ctx.group, %{
          "is_data" => true,
          "content" => "data",
          "data" => %{"a" => 1}
        })

      assert reads(ctx.owner, data) == :nothing

      {:ok, _deleted} = Social.delete_value(ctx.owner, ctx.message)
      assert reads(ctx.owner, ctx.message) == :nothing
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

  defp create_group_with!(owner, name, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        Social.get_root_group!(),
        Map.merge(
          %{"name" => name, "description" => "", "description_format" => :markdown},
          attrs
        )
      )

    group
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
