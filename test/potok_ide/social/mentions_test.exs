defmodule PotokIde.Social.MentionsTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications
  alias PotokIde.Social
  alias PotokIde.Social.Mentions

  describe "extract/1" do
    test "finds handles, also without trailing punctuation" do
      assert Mentions.extract("hi @Ana and @bob.") == ["ana", "bob.", "bob"]
    end

    test "skips e-mail addresses and code" do
      content = """
      mail ana@example.com, see `@inline` and

      ```
      @fenced
      ```
      """

      assert Mentions.extract(content) == []
    end
  end

  describe "resolve/3" do
    setup do
      author = profile!("men-author")
      ana = profile!("men-ana")
      bob = profile!("men-bob")
      outsider = profile!("men-out")
      group = group!(author, "men-group")
      add_member!(author, group, ana)
      add_member!(author, group, bob)

      %{author: author, ana: ana, bob: bob, outsider: outsider, group: group}
    end

    test "mentions members by username and never reaches outsiders or the author", ctx do
      assert {%{"profiles" => ["men-ana", "men-author"]}, [ana_id]} =
               Mentions.resolve("hey @Men-Ana, @men-out and @men-author", ctx.author, ctx.group)

      assert ana_id == ctx.ana.id
    end

    test "a role reaches its members and everyone reaches the whole group", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.author, ctx.group)
      {:ok, team} = Social.create_group_role(ctx.author, ctx.group, %{"name" => "team"})
      {:ok, _} = Social.assign_group_member_role(ctx.author, ctx.group, ctx.bob.id, team.key)

      assert {%{"roles" => ["team"]}, [bob_id]} =
               Mentions.resolve("ping @team", ctx.author, ctx.group)

      assert bob_id == ctx.bob.id

      assert {%{"roles" => ["everyone"]}, ids} =
               Mentions.resolve("@everyone hello", ctx.author, ctx.group)

      assert ids == Enum.sort([ctx.ana.id, ctx.bob.id])
    end

    test "a role wins over a username with the same name", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.author, ctx.group)
      {:ok, _role} = Social.create_group_role(ctx.author, ctx.group, %{"name" => "men-ana"})

      assert {%{"roles" => ["men-ana"]}, []} =
               Mentions.resolve("@men-ana", ctx.author, ctx.group)
    end

    test "roles are not mentioned without the mention_roles permission", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.author, ctx.group)

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.author,
          ctx.group,
          "everyone",
          :mention_roles,
          :neutral
        )

      assert {%{}, []} = Mentions.resolve("@everyone", ctx.ana, ctx.group)

      assert {%{"profiles" => ["men-bob"]}, [_bob_id]} =
               Mentions.resolve("@everyone @men-bob", ctx.ana, ctx.group)
    end
  end

  describe "highlight/2" do
    test "wraps resolved handles outside code and links" do
      html = ~s(<p>hi @Ana, @team. <code>@ana</code> <a href="/x">@ana</a> @nobody</p>)
      mentions = %{"profiles" => ["ana"], "roles" => ["team"]}

      assert Mentions.highlight(html, mentions) ==
               ~s(<p>hi <span class="mention mention-profile" data-mention="ana">@Ana</span>, ) <>
                 ~s(<span class="mention mention-role" data-mention="team">@team</span>. ) <>
                 ~s(<code>@ana</code> <a href="/x">@ana</a> @nobody</p>)
    end

    test "leaves html without mentions untouched" do
      assert Mentions.highlight("<p>@ana</p>", %{}) == "<p>@ana</p>"
    end
  end

  describe "chat values" do
    test "store their mentions and notify mentioned members once" do
      request_pid = self()
      configure_push_notifications(request_pid)

      author_account = account_fixture()
      ana_account = account_fixture()
      author = profile!("val-author", author_account)
      ana = profile!("val-ana", ana_account)
      group = group!(author, "val-group")
      add_member!(author, group, ana)

      {:ok, ana_subscription} =
        Accounts.upsert_push_subscription(Accounts.get_account!(ana_account.id), push_attrs())

      assert {:ok, value} = Social.create_value(author, group, %{"content" => "hi @val-ana"})
      assert value.mentions == %{"profiles" => ["val-ana"]}
      assert value.mentioned_profile_ids == [ana.id]

      assert_receive {:push_request, request_options}
      assert request_options[:url] == ana_subscription.endpoint
      refute_receive {:push_request, _duplicate}

      assert {:ok, updated} = Social.update_value(author, value, %{"content" => "never mind"})
      assert updated.mentions == %{}
      assert updated.mentioned_profile_ids == []
      refute_receive {:push_request, _edit}
    end
  end

  defp profile!(username, account \\ account_fixture()) do
    {:ok, profile} =
      Social.create_profile_for_account(account, %{
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

  defp push_attrs do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      endpoint:
        "https://updates.push.services.mozilla.com/wpush/v2/#{System.unique_integer([:positive])}",
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      p256dh: Base.url_encode64(public_key, padding: false),
      expires_at: nil,
      user_agent: "ExUnit"
    }
  end

  defp configure_push_notifications(request_pid) do
    original_config = Application.get_env(:potok_ide, PushNotifications, [])
    on_exit(fn -> Application.put_env(:potok_ide, PushNotifications, original_config) end)

    Application.put_env(
      :potok_ide,
      PushNotifications,
      ttl: 60,
      vapid_subject: "mailto:test@example.com",
      vapid_public_key: Base.url_encode64(<<4>> <> :crypto.strong_rand_bytes(64), padding: false),
      vapid_private_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      request_fun: fn options ->
        send(request_pid, {:push_request, options})
        {:ok, %Req.Response{status: 201, body: ""}}
      end
    )
  end
end
