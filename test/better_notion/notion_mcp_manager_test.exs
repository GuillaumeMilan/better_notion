defmodule BetterNotion.NotionMcpManagerTest do
  use ExUnit.Case, async: true

  alias BetterNotion.NotionMcpManager

  describe "update_page_args/3" do
    test "builds a bare update_properties call when no icon/cover given" do
      assert NotionMcpManager.update_page_args("abc", %{"Status*" => "Done"}, []) ==
               %{
                 "page_id" => "abc",
                 "command" => "update_properties",
                 "properties" => %{"Status*" => "Done"}
               }
    end

    test "icon-only update keeps an empty properties map (required by the tool)" do
      args = NotionMcpManager.update_page_args("abc", %{}, icon: "🚀")

      assert args["properties"] == %{}
      assert args["icon"] == "🚀"
      refute Map.has_key?(args, "cover")
    end

    test "includes cover when provided" do
      args = NotionMcpManager.update_page_args("abc", %{}, cover: "https://example.com/c.jpg")

      assert args["cover"] == "https://example.com/c.jpg"
      refute Map.has_key?(args, "icon")
    end

    test "sets properties, icon, and cover together in one call" do
      args =
        NotionMcpManager.update_page_args("abc", %{"Status*" => "Done"},
          icon: "✅",
          cover: "https://example.com/c.jpg"
        )

      assert args == %{
               "page_id" => "abc",
               "command" => "update_properties",
               "properties" => %{"Status*" => "Done"},
               "icon" => "✅",
               "cover" => "https://example.com/c.jpg"
             }
    end

    test "omits icon/cover keys when their value is nil (leave unchanged)" do
      args = NotionMcpManager.update_page_args("abc", %{}, icon: nil, cover: nil)

      refute Map.has_key?(args, "icon")
      refute Map.has_key?(args, "cover")
    end
  end
end
