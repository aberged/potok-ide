defmodule PotokIde.ImageMagick do
  @moduledoc """
  Runs ImageMagick. It is in the release image and on most developers'
  machines, and every caller has a way on without it.
  """

  @doc "The executable and how to call it, or nil."
  def find do
    # Prefer `magick` because Windows has a built-in `convert.exe` disk utility.
    case :os.type() do
      {:win32, _} ->
        case System.find_executable("magick") || System.find_executable("magick.exe") do
          nil -> nil
          path -> {path, :magick}
        end

      _ ->
        cond do
          magick = System.find_executable("magick") -> {magick, :magick}
          convert = System.find_executable("convert") -> {convert, :convert}
          true -> nil
        end
    end
  end

  @doc "`{:ok, output}` for `args` in the order ImageMagick 7 reads them."
  def run(args) when is_list(args) do
    case find() do
      {executable, _kind} -> command(executable, args)
      nil -> {:error, :imagemagick_not_found}
    end
  end

  @doc "`{:ok, output}` for `args` in the order of the old `convert`, which applies settings first."
  def convert(args) when is_list(args) do
    case find() do
      {magick, :magick} -> command(magick, ["convert" | args])
      {convert, :convert} -> command(convert, args)
      nil -> {:error, :imagemagick_not_found}
    end
  end

  defp command(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, status, output}}
    end
  end
end
