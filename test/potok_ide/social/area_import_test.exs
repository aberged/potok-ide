defmodule PotokIde.Social.AreaImportTest do
  @moduledoc """
  Areas from a GeoJSON file as groups (`AreaImport`): a municipality under the
  root with the union of its local communities, each of them a group below it
  with its own border, made by a profile of the import's own.
  """
  use PotokIde.DataCase, async: true

  @moduletag :tmp_dir

  import Ecto.Query
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts.Account
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AreaImport, Group, GroupAreas, Profile}

  @keys [name: "mz_imel", parent: "opstina_imel"]

  # A square `half` degrees around the centre, as GeoJSON rings.
  defp square({lat, lng}, half) do
    [
      [
        [lng - half, lat - half],
        [lng + half, lat - half],
        [lng + half, lat + half],
        [lng - half, lat + half],
        [lng - half, lat - half]
      ]
    ]
  end

  defp feature(parent, name, geometry) do
    %{
      "type" => "Feature",
      "properties" => %{"mz_imel" => name, "opstina_imel" => parent, "objectid" => "1"},
      "geometry" => geometry
    }
  end

  defp polygon(rings), do: %{"type" => "Polygon", "coordinates" => rings}

  # Two municipalities: one with neighbours that share an edge and two
  # communities of one name, one with a community in two parts and one whose
  # border crosses itself.
  defp features do
    [
      feature("PETROVAC NA MLAVI", "CENTAR", polygon(square({44.30, 21.40}, 0.01))),
      feature("PETROVAC NA MLAVI", "SUVI DO", polygon(square({44.30, 21.42}, 0.01))),
      feature("PETROVAC NA MLAVI", "VRELO", polygon(square({44.32, 21.40}, 0.01))),
      feature("PETROVAC NA MLAVI", "VRELO", polygon(square({44.32, 21.42}, 0.01))),
      feature("PALILULA (BEOGRAD)", "KUMODRAŽ I", %{
        "type" => "MultiPolygon",
        "coordinates" => [square({44.80, 20.50}, 0.01), square({44.80, 20.55}, 0.01)]
      }),
      feature(
        "PALILULA (BEOGRAD)",
        "MAŠNA",
        polygon([
          [[20.60, 44.80], [20.62, 44.82], [20.62, 44.80], [20.60, 44.82], [20.60, 44.80]]
        ])
      ),
      # Without a name, it is left out.
      feature("PALILULA (BEOGRAD)", "", polygon(square({44.9, 20.6}, 0.01)))
    ]
  end

  defp write_file!(dir) do
    path = Path.join(dir, "areas.geojson")

    File.write!(
      path,
      Jason.encode!(%{"type" => "FeatureCollection", "features" => features()})
    )

    path
  end

  defp made_by(%Profile{id: id}) do
    from(g in Group, where: g.creator_id == ^id, order_by: g.name) |> Repo.all()
  end

  setup %{tmp_dir: dir} do
    {account, own} = account_with_profile!("area-importer")
    {_account, outsider} = account_with_profile!("area-outsider")

    %{path: write_file!(dir), account: account, own: own, outsider: outsider}
  end

  describe "an import" do
    test "makes the municipalities under the root and the communities below them",
         %{path: path, account: account, own: own} do
      assert {:ok, report} = AreaImport.import_file(path, account.email, "mesne_zajednice", @keys)

      assert report.parents == 2
      assert report.children == 6
      assert report.created == 8
      assert report.areas == 8
      assert report.repaired == 1
      assert report.failed == []

      # A profile of its own on the account, which keeps the one it uses.
      profile = Repo.get_by!(Profile, username: "mesne_zajednice")
      assert Repo.get!(Account, account.id).current_profile_id == own.id
      assert made_by(own) == []

      root = Social.get_root_group!()
      groups = made_by(profile)
      parents = Enum.filter(groups, &(&1.parent_id == root.id))

      assert Enum.map(parents, & &1.name) == ["Palilula (Beograd)", "Petrovac na Mlavi"]

      children = groups -- parents

      assert Enum.map(children, & &1.name) |> Enum.sort() ==
               ["Centar", "Kumodraž I", "Mašna", "Suvi Do", "Vrelo", "Vrelo"]

      for group <- parents do
        assert group.pin_icon == "municipality"
      end

      for group <- children do
        assert group.pin_icon == "local_community"
        assert group.parent_id in Enum.map(parents, & &1.id)
        refute group.inherits_members
      end

      for group <- groups do
        assert group.is_public
        assert group.preset == :page
        assert group.home_page == :description
        assert %Geo.MultiPolygon{} = Social.load_area(group).area
      end

      # Every pin stands inside its own area.
      assert from(g in Group,
               where:
                 g.creator_id == ^profile.id and
                   fragment(
                     "NOT ST_Intersects(?, ST_SetSRID(ST_MakePoint(?, ?), 4326))",
                     g.area,
                     g.longitude,
                     g.latitude
                   )
             )
             |> Repo.aggregate(:count) == 0
    end

    test "a municipality's area is the union of its communities and holds them",
         %{path: path, account: account, outsider: outsider} do
      {:ok, _report} = AreaImport.import_file(path, account.email, "mesne_zajednice", @keys)
      profile = Repo.get_by!(Profile, username: "mesne_zajednice")
      groups = made_by(profile)
      petrovac = Enum.find(groups, &(&1.name == "Petrovac na Mlavi"))
      centar = Enum.find(groups, &(&1.name == "Centar"))
      kumodraz = Enum.find(groups, &(&1.name == "Kumodraž I"))

      # Four squares that touch make one polygon with no hole.
      assert %Geo.MultiPolygon{coordinates: [[_outer]]} = Social.load_area(petrovac).area

      # Two parts stay two parts.
      assert %Geo.MultiPolygon{coordinates: [_, _]} = Social.load_area(kumodraz).area

      assert [%Group{id: id}] = GroupAreas.containing(outsider, centar)
      assert id == petrovac.id
    end

    test "a municipality keeps a real hole and closes the gaps between neighbours",
         %{tmp_dir: dir, account: account} do
      rect = fn w, s, e, n -> [[[w, s], [e, s], [e, n], [w, n], [w, s]]] end

      features = [
        # Two neighbours 0.0002° (~16 m) apart, joined above and below: the
        # gap between them is a hole of ~18,000 m², but a thin one.
        feature("TITEL", "LEVO", polygon(rect.(21.00, 44.00, 21.01, 44.01))),
        feature("TITEL", "DESNO", polygon(rect.(21.0102, 44.00, 21.0202, 44.01))),
        feature("TITEL", "GORE", polygon(rect.(21.00, 44.01, 21.0202, 44.015))),
        feature("TITEL", "DOLE", polygon(rect.(21.00, 43.995, 21.0202, 44.00))),
        # A community round a lake that is no one's.
        feature(
          "ŽABARI",
          "JEZERO",
          polygon(rect.(21.10, 44.00, 21.13, 44.03) ++ rect.(21.11, 44.01, 21.12, 44.02))
        )
      ]

      path = Path.join(dir, "holes.geojson")
      File.write!(path, Jason.encode!(%{"type" => "FeatureCollection", "features" => features}))

      {:ok, %{failed: []}} = AreaImport.import_file(path, account.email, "mesne_zajednice", @keys)
      groups = made_by(Repo.get_by!(Profile, username: "mesne_zajednice"))

      titel = Enum.find(groups, &(&1.name == "Titel"))
      assert %Geo.MultiPolygon{coordinates: [[_outer]]} = Social.load_area(titel).area

      zabari = Enum.find(groups, &(&1.name == "Žabari"))
      assert %Geo.MultiPolygon{coordinates: [[_outer, _lake]]} = Social.load_area(zabari).area
    end

    test "running it again makes nothing new", %{path: path, account: account} do
      {:ok, _report} = AreaImport.import_file(path, account.email, "mesne_zajednice", @keys)
      count = Repo.aggregate(Group, :count)

      assert {:ok, report} = AreaImport.import_file(path, account.email, "mesne_zajednice", @keys)
      assert report.created == 0
      assert report.reused == 8
      assert report.areas == 0
      assert report.failed == []
      assert Repo.aggregate(Group, :count) == count
    end

    test "goes on where it stopped", %{path: path, account: account} do
      {:ok, _report} = AreaImport.import_file(path, account.email, "mesne_zajednice", @keys)
      profile = Repo.get_by!(Profile, username: "mesne_zajednice")
      centar = Enum.find(made_by(profile), &(&1.name == "Centar"))

      # As if it stopped after making the group, before its border.
      Repo.update_all(from(g in Group, where: g.id == ^centar.id),
        set: [area: nil, latitude: nil, longitude: nil, pin_icon: nil]
      )

      assert {:ok, report} = AreaImport.import_file(path, account.email, "mesne_zajednice", @keys)
      assert report.created == 0
      # Its border, and its municipality's again.
      assert report.areas == 2
      assert Repo.get!(Group, centar.id).pin_icon == "local_community"
    end

    test "remove/1 takes it all away", %{path: path, account: account} do
      {:ok, _report} = AreaImport.import_file(path, account.email, "mesne_zajednice", @keys)
      profile = Repo.get_by!(Profile, username: "mesne_zajednice")

      assert {:ok, 8, 0} = AreaImport.remove(profile)
      assert made_by(profile) == []
    end

    test "a name another account has is not taken", %{path: path, account: account} do
      assert {:error, :username_taken} =
               AreaImport.import_file(path, account.email, "area-outsider", @keys)

      assert {:error, :no_account} =
               AreaImport.import_file(path, "nobody@example.com", "mesne_zajednice", @keys)
    end
  end

  describe "title_case/1" do
    test "writes names as names are written" do
      for {upper, name} <- [
            {"CRVENA REKA", "Crvena Reka"},
            {"PETROVAC NA MLAVI", "Petrovac na Mlavi"},
            {"ĆIRILO I METODIJE", "Ćirilo i Metodije"},
            {"KUMODRAŽ I", "Kumodraž I"},
            {"MEDAKOVIĆ III", "Medaković III"},
            {"SUVI DO", "Suvi Do"},
            {"2. MZ SLOBODAN BAJIĆ PAJA", "2. MZ Slobodan Bajić Paja"},
            {"3. MZ 29. NOVEMBAR", "3. MZ 29. Novembar"},
            {"MALE PČELICE-NOVO NASELJE", "Male Pčelice-Novo Naselje"},
            {"PALILULA (BEOGRAD)", "Palilula (Beograd)"},
            {"BLOK B", "Blok B"},
            {"LJUBOVIJA 1", "Ljubovija 1"},
            {"ŽITNI TRG", "Žitni Trg"}
          ] do
        assert AreaImport.title_case(upper) == name
      end
    end
  end
end
