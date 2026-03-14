defmodule BetterNotionTest do
  use ExUnit.Case
  doctest BetterNotion

  test "greets the world" do
    assert BetterNotion.hello() == :world
  end
end
