defmodule PotokIdeWeb.DistanceTest do
  use ExUnit.Case, async: true

  alias PotokIdeWeb.Distance

  test "metres to the nearest ten, one decimal below ten kilometres, then whole ones" do
    Gettext.with_locale(PotokIdeWeb.Gettext, "en", fn ->
      assert Distance.text(0) == "0 m"
      assert Distance.text(847) == "850 m"
      assert Distance.text(1_349) == "1.3 km"
      assert Distance.text(9_940) == "9.9 km"
      assert Distance.text(12_400) == "12 km"
    end)
  end

  test "Serbian writes a decimal comma" do
    Gettext.with_locale(PotokIdeWeb.Gettext, "sr", fn ->
      assert Distance.text(1_349) == "1,3 km"
      assert Distance.text(850) == "850 m"
    end)
  end
end
