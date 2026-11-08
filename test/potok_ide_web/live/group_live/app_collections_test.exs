defmodule PotokIdeWeb.GroupLive.AppCollectionsTest do
  @moduledoc """
  An app's collections through the App API: what each viewer may call, which
  live changes reach whose frame, and a file sent from the frame.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, Value, ValueAttachment}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("ac#{unique()}")
    {member_account, member} = account_with_profile!("ac#{unique()}")
    {reader_account, reader} = account_with_profile!("ac#{unique()}")

    group =
      group_with_members!(owner, [member, reader], %{
        "uses_api" => true,
        "description" => "<p>form</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, role} = Social.create_group_role(owner, group, %{"name" => "pregled"})
    {:ok, _assigned} = Social.assign_group_member_role(owner, group, reader.id, role.key)

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      reader: reader,
      reader_account: reader_account,
      role: role.key,
      group: Social.get_group!(group.id)
    }
  end

  defp open_app(account, group) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> live(~p"/groups/#{group.id}/group_home")

    lv
  end

  defp call(lv, method, params \\ %{}) do
    render_hook(lv, "app_api", %{method: method, params: params, app_id: ""})
    assert_reply(lv, reply)
    reply
  end

  defp form_rules(ctx, extra \\ %{}) do
    %{"responses" => Map.merge(%{"read" => [ctx.role], "under" => ["a"]}, extra)}
  end

  test "an editor saves the config and a member sees what they may do", ctx do
    owner = open_app(ctx.owner_account, ctx.group)

    assert %{ok: true, config: %{revision: 0}} =
             call(owner, "save_config", %{
               data:
                 Jason.encode!(%{"rules" => form_rules(ctx), "form" => %{"title" => "Prijava"}}),
               revision: 0
             })

    assert %{ok: false, error: "conflict", current: %{revision: 0}} =
             call(owner, "save_config", %{data: Jason.encode!(%{"form" => %{}}), revision: 5})

    member = open_app(ctx.member_account, ctx.group)

    assert %{
             ok: true,
             config: %{data: %{"form" => %{"title" => "Prijava"}}},
             caps: caps,
             manage: false
           } =
             call(member, "get_config")

    assert %{write: true, read: "own", written: false} = caps["responses"]

    assert %{ok: false, error: "forbidden"} =
             call(member, "save_config", %{data: Jason.encode!(%{}), revision: 0})
  end

  test "answers go in through the API and each viewer lists what the rule allows", ctx do
    {:ok, _config} =
      AppData.save_config(ctx.owner, ctx.group, nil, %{"rules" => form_rules(ctx)}, 0)

    member = open_app(ctx.member_account, ctx.group)

    assert %{ok: true, value: %{collection: "responses", creator_id: creator_id}} =
             call(member, "insert_value", %{
               collection: "responses",
               data: Jason.encode!(%{"a" => %{"q1" => "o1"}})
             })

    assert creator_id == ctx.member.id

    owner = open_app(ctx.owner_account, ctx.group)

    call(owner, "insert_value", %{
      collection: "responses",
      data: Jason.encode!(%{"a" => %{"q1" => "o2"}})
    })

    assert %{ok: true, values: [_own], total: 1} =
             call(member, "list_values", %{collection: "responses", total: true})

    reader = open_app(ctx.reader_account, ctx.group)

    assert %{ok: true, values: [%{data: %{"a" => %{"q1" => "o2"}}}, _older], total: 2} =
             call(reader, "list_values", %{
               collection: "responses",
               total: true,
               order_dir: "desc"
             })

    assert %{ok: true, summary: %{total: 2, keys: %{"q1" => %{answered: 2}}}} =
             call(reader, "summarize_values", %{collection: "responses", keys: ["q1"]})

    assert %{ok: false, error: "forbidden"} =
             call(member, "summarize_values", %{collection: "responses", keys: ["q1"]})

    # Apps that use no collections never see these values.
    assert %{ok: true, values: []} = call(reader, "list_values", %{})
  end

  test "a new answer reaches its author and the readers, and no other member", ctx do
    {:ok, _config} =
      AppData.save_config(
        ctx.owner,
        ctx.group,
        nil,
        %{"rules" => form_rules(ctx, %{"anonymous" => true})},
        0
      )

    member = open_app(ctx.member_account, ctx.group)
    reader = open_app(ctx.reader_account, ctx.group)
    {other_account, other} = account_with_profile!("ac#{unique()}")
    add_member!(ctx.owner, ctx.group, other)
    bystander = open_app(other_account, ctx.group)

    {:ok, value, _rule} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "responses", %{
        "a" => %{"q1" => "o1"}
      })

    id = value.id
    member_id = ctx.member.id

    # The page has dealt with the broadcast once it answers.
    render(member)
    render(reader)

    assert_push_event member, "app_value", %{
      event: "created",
      value: %{id: ^id, creator_id: ^member_id}
    }

    assert_push_event reader, "app_value", %{event: "created", value: %{id: ^id, creator_id: nil}}

    render(bystander)
    refute_push_event bystander, "app_value", %{event: "created"}
    refute_push_event reader, "new_data_value", %{}
  end

  test "a new config reaches every frame as its revision only", ctx do
    member = open_app(ctx.member_account, ctx.group)

    {:ok, config} =
      AppData.save_config(ctx.owner, ctx.group, nil, %{"rules" => form_rules(ctx)}, 0)

    config_id = config.id
    render(member)

    assert_push_event member,
                      "app_value",
                      %{event: "config", id: ^config_id, revision: 0} = message

    refute Map.has_key?(message, :value)
  end

  test "roles for a form to name", ctx do
    member = open_app(ctx.member_account, ctx.group)

    assert %{ok: true, roles: roles} = call(member, "list_roles")
    assert Enum.any?(roles, &(&1.key == ctx.role and &1.name == "pregled" and not &1.builtin))
    assert Enum.any?(roles, &(&1.key == "everyone" and &1.builtin))
  end

  test "a file sent from the frame lands in the private group and the value takes it", ctx do
    {:ok, _config} =
      AppData.save_config(
        ctx.owner,
        ctx.group,
        nil,
        %{
          "rules" =>
            form_rules(ctx, %{
              "uploads" => %{"cv" => %{"target" => "private", "types" => ["pdf"]}}
            })
        },
        0
      )

    owner = open_app(ctx.owner_account, ctx.group)
    assert %{ok: true, files: %{"private" => private_id}} = call(owner, "ensure_file_groups")

    member = open_app(ctx.member_account, ctx.group)

    assert %{ok: true, ref: ref} =
             call(member, "prepare_upload", %{
               collection: "responses",
               slot: "cv",
               name: "cv.pdf",
               size: 8,
               type: "application/pdf"
             })

    member
    |> file_input("#group-app-upload-form", :app_file, [
      %{name: "cv.pdf", content: "%PDF-1.4", type: "application/pdf"}
    ])
    |> render_upload("cv.pdf")

    assert_push_event member, "app_upload_done", %{ref: ^ref, ok: true, file: %{file: file_id}}

    attachment = Repo.get!(ValueAttachment, file_id)
    assert attachment.group_id == private_id

    assert %{ok: true, value: _value} =
             call(member, "insert_value", %{
               collection: "responses",
               data: Jason.encode!(%{"a" => %{"cv" => [%{"file" => file_id}]}})
             })

    assert Repo.get!(Value, attachment.value_id).data["response"]

    assert %{ok: true, url: "http" <> _} = call(member, "file_url", %{id: file_id})

    reader = open_app(ctx.reader_account, ctx.group)
    assert %{ok: false, error: "not_found"} = call(reader, "file_url", %{id: file_id})
  end

  test "a file the app did not announce is refused", ctx do
    {:ok, _config} =
      AppData.save_config(
        ctx.owner,
        ctx.group,
        nil,
        %{"rules" => form_rules(ctx, %{"uploads" => %{"cv" => %{"target" => "private"}}})},
        0
      )

    owner = open_app(ctx.owner_account, ctx.group)
    call(owner, "ensure_file_groups")
    member = open_app(ctx.member_account, ctx.group)

    member
    |> file_input("#group-app-upload-form", :app_file, [
      %{name: "other.pdf", content: "%PDF-1.4", type: "application/pdf"}
    ])
    |> render_upload("other.pdf")

    refute Repo.exists?(ValueAttachment)
  end
end
