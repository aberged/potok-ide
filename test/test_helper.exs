ExUnit.start(exclude: if(PotokIde.ImageMagick.find(), do: [], else: [:imagemagick]))
Ecto.Adapters.SQL.Sandbox.mode(PotokIde.Repo, :manual)
