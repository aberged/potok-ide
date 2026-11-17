defmodule PotokIde.Repo.Migrations.AddPlainGroupsIndex do
  use Ecto.Migration

  # The groups that are not records apps keep as groups (`external_key`), so
  # a profile's memberships can be narrowed to them from the few plain groups
  # rather than by reading every record it is in. On the dev database a
  # profile in 199,695 groups, 83 of them plain, waited 265 ms for that
  # narrowing and 8 ms with this index; the column of its groups went from
  # 1.1 s to about 0.44 s, and the header's counts use the same narrowing.
  def change do
    create index(:groups, [:id], where: "external_key IS NULL", name: :groups_plain_id_index)
  end
end
