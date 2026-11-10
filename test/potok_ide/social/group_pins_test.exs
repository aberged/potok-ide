defmodule PotokIde.Social.GroupPinsTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.{Group, GroupPins, GroupPresets}
  alias PotokIdeWeb.PinIcons

  test "every key is different, and every pin has a drawing and a name" do
    keys = GroupPins.keys()
    assert keys == Enum.uniq(keys)

    for {key, icon, tone} <- GroupPins.icons() do
      assert [_ | _] = PinIcons.paths(icon)
      assert is_binary(PinIcons.label(key)) and PinIcons.label(key) != ""
      assert GroupPins.tone_color(tone) =~ ~r/^#[0-9a-f]{6}$/
    end
  end

  test "there is a kind for every preset, an app and none" do
    kinds = Enum.map(GroupPins.kinds(), &elem(&1, 0))

    for preset <- GroupPresets.keys() ++ ["app", "none"] do
      assert preset in kinds, preset
      assert PinIcons.kind_look(preset).paths != []
    end
  end

  test "a municipality and a local community have pins, the internet no longer does" do
    assert {"municipality", "identification", :places} in GroupPins.icons()
    assert {"local_community", "home-modern", :community} in GroupPins.icons()
    refute "internet" in GroupPins.keys()
  end

  test "a group shows its own pin while the list has it, its kind's otherwise" do
    assert GroupPins.pin(%Group{pin_icon: "shop"}) == "shop"
    assert GroupPins.pin(%Group{pin_icon: "picture"}) == "picture"
    assert GroupPins.pin(%Group{pin_icon: "retired"}) == nil
    assert GroupPins.pin(%Group{pin_icon: "internet"}) == nil
    assert GroupPins.pin(%Group{pin_icon: nil}) == nil
  end

  test "a group's kind follows the mark on its avatar" do
    assert GroupPins.kind(%Group{preset: :chat, uses_api: false}) == "chat"
    assert GroupPins.kind(%Group{preset: :questionnaire, uses_api: true}) == "questionnaire"
    assert GroupPins.kind(%Group{preset: :chat, uses_api: true}) == "app"
    assert GroupPins.kind(%Group{preset: nil, uses_api: false}) == "none"
  end

  test "the catalogue a map gets names its tones and draws each pin" do
    catalogue = PinIcons.catalogue()

    assert catalogue.drop =~ ~r/^M16 /
    assert Enum.all?(catalogue.icons, &Map.has_key?(catalogue.tones, &1.tone))
    assert length(catalogue.icons) == length(GroupPins.icons())
  end
end
