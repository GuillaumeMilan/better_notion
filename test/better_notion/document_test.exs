defmodule BetterNotion.DocumentTest do
  use ExUnit.Case, async: true

  describe "compute_updates/2" do
    test "returns empty list when contents are identical" do
      content = "# Title\n\nSome text here."
      assert BetterNotion.Document.compute_updates(content, content) == []
    end

    test "detects a single line change with surrounding context" do
      server = "line1\nline2\nline3"
      updated = "line1\nmodified\nline3"

      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "line1\nline2\nline3", new_str: "line1\nmodified\nline3"}
             ]
    end

    test "detects an insertion with surrounding context" do
      server = "line1\nline3"
      updated = "line1\nline2\nline3"

      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "line1\nline3", new_str: "line1\nline2\nline3"}
             ]
    end

    test "detects a deletion with surrounding context" do
      server = "line1\nline2\nline3"
      updated = "line1\nline3"

      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "line1\nline2\nline3", new_str: "line1\nline3"}
             ]
    end

    test "detects multiple separate changes with context" do
      server = "a\nb\nc\nd\ne"
      updated = "a\nB\nc\nD\ne"

      result = BetterNotion.Document.compute_updates(server, updated)

      assert result == [
               %{old_str: "a\nb\nc", new_str: "a\nB\nc"},
               %{old_str: "c\nd\ne", new_str: "c\nD\ne"}
             ]
    end

    test "handles change at the beginning (context after only)" do
      server = "first\nsecond\nthird"
      updated = "FIRST\nsecond\nthird"

      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "first\nsecond", new_str: "FIRST\nsecond"}
             ]
    end

    test "handles change at the end (context before only)" do
      server = "first\nsecond\nthird"
      updated = "first\nsecond\nTHIRD"

      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "second\nthird", new_str: "second\nTHIRD"}
             ]
    end

    test "handles adjacent del and ins as a single chunk with context" do
      server = "a\nb\nc"
      updated = "a\nX\nY\nc"

      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "a\nb\nc", new_str: "a\nX\nY\nc"}
             ]
    end

    test "handles complete replacement" do
      server = "old1\nold2\nold3"
      updated = "new1\nnew2"

      result = BetterNotion.Document.compute_updates(server, updated)

      assert result == [
               %{old_str: "old1\nold2\nold3", new_str: "new1\nnew2"}
             ]
    end

    test "handles empty server content" do
      server = ""
      updated = "new line"

      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "", new_str: "new line"}
             ]
    end

    test "handles empty updated content" do
      server = "some content"
      updated = ""

      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "some content", new_str: ""}
             ]
    end

    test "expands context to ensure uniqueness with repeated patterns" do
      server = "line\nline\nline\nline"
      updated = "line\nLINE\nline\nline"

      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "line\nline\nline\nline", new_str: "line\nLINE\nline\nline"}
             ]
    end

    test "new_str of an earlier chunk does not pollute old_str matching of a later chunk" do
      # Chunk 1 replaces "section_a" with new content that includes "shared_pattern".
      # Chunk 2 replaces "shared_pattern" further down in the original.
      # Without position-aware search, chunk 2 would accidentally target the copy
      # introduced by chunk 1 instead of the original occurrence.
      server = "section_a\nshared_pattern\nold_value\nshared_pattern\nother"
      updated = "new_content\nshared_pattern\nnew_value\nshared_pattern\nother"

      result = BetterNotion.Document.compute_updates(server, updated)

      # Simulate sequential application and verify the result matches `updated`
      final =
        Enum.reduce(result, server, fn %{old_str: old, new_str: new}, content ->
          String.replace(content, old, new, global: false)
        end)

      assert final == updated
    end

    test "new_str introducing exact duplicate of a later old_str: sequential apply produces correct result" do
      # chunk 1: replaces "AAA" with "BBB\nTARGET\nCCC" — now "TARGET" appears twice
      # chunk 2: replaces "TARGET" (the original one) with "DONE"
      server = "AAA\nTARGET\nZZZ"
      updated = "BBB\nTARGET\nCCC\nDONE\nZZZ"

      result = BetterNotion.Document.compute_updates(server, updated)

      final =
        Enum.reduce(result, server, fn %{old_str: old, new_str: new}, content ->
          String.replace(content, old, new, global: false)
        end)

      assert final == updated
    end

    test "expands context only as much as needed" do
      server = "a\nb\nrepeat\nrepeat\nc\nd"
      updated = "a\nb\nrepeat\nCHANGED\nc\nd"

      # "repeat\nrepeat" is not unique but with 1 line context before/after:
      # "b\nrepeat\nc" is unique — no need to go further
      assert BetterNotion.Document.compute_updates(server, updated) == [
               %{old_str: "repeat\nrepeat\nc", new_str: "repeat\nCHANGED\nc"}
             ]
    end

    test "works with markdown content" do
      server = """
      # My Document

      This is the first paragraph.

      ## Section 1

      Some content here.

      ## Section 2

      More content here.\
      """

      updated = """
      # My Document

      This is the first paragraph.

      ## Section 1

      Updated content here.

      ## Section 2

      More content here.\
      """

      result = BetterNotion.Document.compute_updates(server, updated)

      assert result == [
               %{
                 old_str: "\nSome content here.\n",
                 new_str: "\nUpdated content here.\n"
               }
             ]
    end
  end
end
