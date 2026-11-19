excluded =
  [
    if(PotokIde.ImageMagick.find(), do: nil, else: :imagemagick),
    if(System.find_executable("node"), do: nil, else: :node)
  ]
  |> Enum.reject(&is_nil/1)

ExUnit.start(exclude: excluded)
Ecto.Adapters.SQL.Sandbox.mode(PotokIde.Repo, :manual)
