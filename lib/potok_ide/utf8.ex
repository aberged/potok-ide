defmodule PotokIde.UTF8 do
  @replacement <<239, 191, 189>>

  def replace_invalid(nil), do: nil

  def replace_invalid(binary) when is_binary(binary) do
    binary
    |> do_replace_invalid([], false)
    |> IO.iodata_to_binary()
  end

  def replace_invalid(value), do: value

  defp do_replace_invalid(<<>>, acc, false), do: Enum.reverse(acc)
  defp do_replace_invalid(<<>>, acc, true), do: Enum.reverse([@replacement | acc])

  defp do_replace_invalid(binary, acc, invalid_run?) do
    case String.next_codepoint(binary) do
      {codepoint, rest} when is_binary(codepoint) ->
        if String.valid?(codepoint) do
          next_acc =
            if invalid_run? do
              [codepoint, @replacement | acc]
            else
              [codepoint | acc]
            end

          do_replace_invalid(rest, next_acc, false)
        else
          do_replace_invalid(rest, acc, true)
        end

      nil ->
        Enum.reverse(acc)
    end
  end
end
