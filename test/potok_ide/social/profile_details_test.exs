defmodule PotokIde.Social.ProfileDetailsTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{ProfileDetails, ProfileFacts, ProfileField}

  defp facts(attrs), do: struct(ProfileFacts, attrs)

  describe "visible?/3" do
    test "the profile's own accounts see everything" do
      holder = facts(holder?: true)

      for audience <- ProfileField.audiences() do
        assert ProfileDetails.visible?(audience, [], holder)
      end
    end

    test "each audience reaches whom it says" do
      stranger = facts([])
      co_member = facts(shared_group_ids: MapSet.new([7]))
      related = facts(relation_group_ids: MapSet.new([9]))

      refute ProfileDetails.visible?(:only_me, [], co_member)

      assert ProfileDetails.visible?(:signed_in, [], stranger)

      refute ProfileDetails.visible?(:shared_groups, [], stranger)
      assert ProfileDetails.visible?(:shared_groups, [], co_member)
      assert ProfileDetails.visible?(:shared_groups, [], related)

      assert ProfileDetails.visible?(:groups, [7], co_member)
      refute ProfileDetails.visible?(:groups, [8], co_member)
      assert ProfileDetails.visible?(:groups, [8, 9], related)
      refute ProfileDetails.visible?(:groups, [7], stranger)
    end

    test "a process or a deleted profile shows nothing, not even to its holder" do
      for kind <- [:process, :deleted] do
        refute ProfileDetails.visible?(:signed_in, [], facts(kind: kind, holder?: true))
      end
    end
  end

  describe "ProfileField.changeset/3" do
    defp field_changeset(key, attrs, allowed \\ []),
      do: ProfileField.changeset(ProfileField.new(1, key), attrs, allowed)

    defp value_errors(changeset), do: for({:value, {message, _}} <- changeset.errors, do: message)

    test "trims a value and checks what the key holds" do
      assert get_change(field_changeset(:first_name, %{"value" => "  Ana  "}), :value) == "Ana"

      assert value_errors(field_changeset(:phone, %{"value" => "+381 64 123-4567"})) == []

      assert value_errors(field_changeset(:phone, %{"value" => "zovi me"})) == [
               "is not a phone number"
             ]

      assert value_errors(field_changeset(:email, %{"value" => "ana@primer.rs"})) == []

      assert value_errors(field_changeset(:email, %{"value" => "ana"})) == [
               "is not an email address"
             ]

      assert value_errors(field_changeset(:place, %{"value" => String.duplicate("a", 81)})) != []
    end

    test "links: a bare domain gets https, at most three, each a link" do
      changeset = field_changeset(:website, %{"value" => "primer.rs\n\n https://ana.rs/o-meni "})

      assert get_change(changeset, :value) == "https://primer.rs\nhttps://ana.rs/o-meni"
      assert changeset.valid?

      four = Enum.map_join(1..4, "\n", &"https://primer#{&1}.rs")

      assert value_errors(field_changeset(:website, %{"value" => four})) == [
               "has more than three links"
             ]

      assert value_errors(field_changeset(:website, %{"value" => "ftp://primer.rs"})) ==
               ["has a line that is not a link"]
    end

    test "keeps picked groups only among the profile's own, and only for picked groups" do
      picked =
        field_changeset(
          :phone,
          %{"value" => "064 111", "audience" => "groups", "group_ids" => ["", "5", "99"]},
          [5, 6]
        )

      assert get_field(picked, :group_ids) == [5]
      assert picked.valid?

      none =
        field_changeset(
          :phone,
          %{"value" => "064 111", "audience" => "groups", "group_ids" => [""]},
          [5]
        )

      assert {"pick at least one group", _} = none.errors[:group_ids]

      others =
        field_changeset(
          :phone,
          %{"value" => "064 111", "audience" => "signed_in", "group_ids" => ["5"]},
          [5]
        )

      assert get_field(others, :group_ids) == []
    end

    test "a blank value is valid and marks the field for deleting" do
      changeset = field_changeset(:first_name, %{"value" => "   "})

      assert changeset.valid?
      assert ProfileField.blank?(changeset)
    end

    test "a new field starts with its default audience" do
      assert ProfileField.new(1, :first_name).audience == :shared_groups
      assert ProfileField.new(1, :phone).audience == :only_me
    end
  end

  describe "saving with the profile" do
    setup do
      {account, profile} = account_with_profile!("detalji#{System.unique_integer([:positive])}")
      %{account: account, profile: profile}
    end

    test "fills, changes and empties fields", %{account: account, profile: profile} do
      assert {:ok, _} =
               Social.update_profile_for_account(account, profile.id, %{}, %{
                 "first_name" => %{"value" => "Ana", "audience" => "signed_in"},
                 "phone" => %{"value" => "064 111 222", "audience" => "only_me"},
                 "place" => %{"value" => "", "audience" => "shared_groups"}
               })

      assert [%{key: :first_name, value: "Ana", audience: :signed_in}, %{key: :phone}] =
               ProfileDetails.list_fields(profile)

      assert {:ok, _} =
               Social.update_profile_for_account(account, profile.id, %{}, %{
                 "first_name" => %{"value" => "Ana", "audience" => "shared_groups"},
                 "phone" => %{"value" => "", "audience" => "only_me"}
               })

      assert [%{key: :first_name, audience: :shared_groups}] = ProfileDetails.list_fields(profile)
    end

    test "a wrong detail saves nothing", %{account: account, profile: profile} do
      assert {:error, {:details, changesets}} =
               Social.update_profile_for_account(account, profile.id, %{description: "O meni"}, %{
                 "first_name" => %{"value" => "Ana", "audience" => "signed_in"},
                 "email" => %{"value" => "nije adresa", "audience" => "signed_in"}
               })

      refute ProfileDetails.valid?(changesets)
      assert ProfileDetails.list_fields(profile) == []
      assert Repo.reload!(profile).description in [nil, ""]
    end

    test "picks groups for a detail and for the description", %{
      account: account,
      profile: profile
    } do
      {_other_account, other} =
        account_with_profile!("drugi#{System.unique_integer([:positive])}")

      group = group_with_members!(profile, [other])
      foreign = group_with_members!(other, [])

      assert [%{id: id, name: name}] = ProfileDetails.group_choices(profile)
      assert id == group.id and name == group.name

      assert {:ok, saved} =
               Social.update_profile_for_account(
                 account,
                 profile.id,
                 %{
                   "description" => "Komšija",
                   "description_audience" => "groups",
                   "description_group_ids" => ["", "#{group.id}", "#{foreign.id}"]
                 },
                 %{
                   "phone" => %{
                     "value" => "064 111",
                     "audience" => "groups",
                     "group_ids" => ["", "#{group.id}", "#{foreign.id}"]
                   }
                 }
               )

      assert saved.description_group_ids == [group.id]
      assert [%{key: :phone, group_ids: [group_id]}] = ProfileDetails.list_fields(profile)
      assert group_id == group.id

      other_facts = ProfileFacts.load(nil, other, saved)
      assert ProfileDetails.description_visible?(saved, other_facts)

      assert [%{key: :phone}] =
               ProfileDetails.visible_fields(ProfileDetails.list_fields(profile), other_facts)

      {_account, stranger} = account_with_profile!("stranac#{System.unique_integer([:positive])}")
      stranger_facts = ProfileFacts.load(nil, stranger, saved)
      refute ProfileDetails.description_visible?(saved, stranger_facts)

      assert ProfileDetails.visible_fields(ProfileDetails.list_fields(profile), stranger_facts) ==
               []
    end

    test "a sub-group that takes in all of its parent's members is not offered", %{
      profile: profile
    } do
      {_account, other} = account_with_profile!("clan#{System.unique_integer([:positive])}")
      group = group_with_members!(profile, [other])
      sub = group_with_members!(profile, [], %{"inherits_members" => true, parent: group})

      assert MapSet.member?(ProfileFacts.load(nil, profile, other).shared_group_ids, sub.id)
      assert ProfileDetails.allowed_group_ids(other) == [group.id]
      assert [%{id: id}] = ProfileDetails.group_choices(other)
      assert id == group.id
    end

    test "a description is seen by its own accounts only, until opened", %{profile: profile} do
      {_account, other} = account_with_profile!("komsija#{System.unique_integer([:positive])}")
      _group = group_with_members!(profile, [other])
      profile = Repo.update!(Ecto.Changeset.change(profile, description: "Volim bicikl"))

      refute ProfileDetails.description_visible?(profile, ProfileFacts.load(nil, other, profile))

      assert ProfileDetails.description_visible?(
               profile,
               ProfileFacts.load(nil, profile, profile)
             )
    end
  end
end
