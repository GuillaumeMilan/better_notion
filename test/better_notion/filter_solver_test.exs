defmodule BetterNotion.FilterSolverTest do
  use ExUnit.Case, async: true

  alias BetterNotion.FilterSolver

  # A schema fixture mirroring the real "TECH TICKETS" data source shape:
  # selects expose a flat "options" list; status exposes "groups".
  defp schema do
    %{
      "Ticket name" => %{"type" => "title"},
      "Team*" => %{
        "type" => "select",
        "options" => [%{"name" => "ExamFlow"}, %{"name" => "ScaleOps"}]
      },
      "Type*" => %{
        "type" => "select",
        "options" => [%{"name" => "Bug"}, %{"name" => "Feature"}]
      },
      "Only*" => %{"type" => "select", "options" => [%{"name" => "Solo"}]},
      "Status*" => %{
        "type" => "status",
        "groups" => %{
          "to_do" => [%{"name" => "TO TRIAGE"}, %{"name" => "BACKLOG"}],
          "in_progress" => [%{"name" => "IN PROGRESS"}, %{"name" => "CODE REVIEW"}],
          "complete" => [%{"name" => "DONE"}]
        }
      },
      "Examflow - sprints" => %{"type" => "relation"},
      "Parent item" => %{"type" => "relation"},
      "Tech Owner*" => %{"type" => "person"}
    }
  end

  defp filter(map), do: %{"filter" => map, "id" => "test"}

  describe "solve/2 — satisfiable operators" do
    test "enum_is sets the option name" do
      filters = [
        filter(%{
          "operator" => "enum_is",
          "property" => "Team*",
          "propertyType" => "select",
          "value" => %{"type" => "exact", "value" => "ExamFlow"}
        })
      ]

      assert {%{"Team*" => "ExamFlow"}, []} = FilterSolver.solve(filters, schema())
    end

    test "relation_contains exact sets a JSON array of page URLs" do
      url = "https://app.notion.com/p/373a8f8de3be81558a60f96de54770fd"

      filters = [
        filter(%{
          "operator" => "relation_contains",
          "property" => "Examflow - sprints",
          "propertyType" => "relation",
          "value" => %{"type" => "exact", "value" => url}
        })
      ]

      assert {%{"Examflow - sprints" => encoded}, []} = FilterSolver.solve(filters, schema())
      assert Jason.decode!(encoded) == [url]
    end

    test "status_is with is_option sets the concrete option" do
      filters = [
        filter(%{
          "operator" => "status_is",
          "property" => "Status*",
          "propertyType" => "status",
          "value" => [%{"type" => "is_option", "value" => "CODE REVIEW"}]
        })
      ]

      assert {%{"Status*" => "CODE REVIEW"}, []} = FilterSolver.solve(filters, schema())
    end

    test "status_is prefers a concrete is_option over an is_group" do
      filters = [
        filter(%{
          "operator" => "status_is",
          "property" => "Status*",
          "propertyType" => "status",
          "value" => [
            %{"type" => "is_group", "value" => "In progress"},
            %{"type" => "is_option", "value" => "TO TRIAGE"}
          ]
        })
      ]

      assert {%{"Status*" => "TO TRIAGE"}, []} = FilterSolver.solve(filters, schema())
    end

    test "status_is resolves an is_group by normalized name to its first option" do
      filters = [
        filter(%{
          "operator" => "status_is",
          "property" => "Status*",
          "propertyType" => "status",
          "value" => [%{"type" => "is_group", "value" => "In progress"}]
        })
      ]

      assert {%{"Status*" => "IN PROGRESS"}, []} = FilterSolver.solve(filters, schema())
    end

    test "enum_is_not picks a different option" do
      filters = [
        filter(%{
          "operator" => "enum_is_not",
          "property" => "Type*",
          "propertyType" => "select",
          "value" => %{"type" => "exact", "value" => "Bug"}
        })
      ]

      assert {%{"Type*" => "Feature"}, []} = FilterSolver.solve(filters, schema())
    end

    test "status_is_not picks an option not excluded (expanding groups)" do
      filters = [
        filter(%{
          "operator" => "status_is_not",
          "property" => "Status*",
          "propertyType" => "status",
          "value" => [
            %{"type" => "is_group", "value" => "complete"},
            %{"type" => "is_option", "value" => "TO TRIAGE"}
          ]
        })
      ]

      {props, warnings} = FilterSolver.solve(filters, schema())
      assert warnings == []
      assert props["Status*"] in ["BACKLOG", "IN PROGRESS", "CODE REVIEW"]
      refute props["Status*"] in ["DONE", "TO TRIAGE"]
    end

    test "is_empty is a no-op" do
      filters = [
        filter(%{
          "operator" => "is_empty",
          "property" => "Parent item",
          "propertyType" => "relation"
        })
      ]

      assert {props, []} = FilterSolver.solve(filters, schema())
      assert props == %{}
    end
  end

  describe "solve/2 — unsatisfiable operators warn and skip" do
    test "person_contains warns and sets nothing" do
      filters = [
        filter(%{
          "operator" => "person_contains",
          "property" => "Tech Owner*",
          "propertyType" => "person",
          "value" => %{"type" => "relative", "value" => "me"}
        })
      ]

      assert {%{}, [warning]} = FilterSolver.solve(filters, schema())
      assert warning =~ "Tech Owner*"
    end

    test "is_not_empty warns and sets nothing" do
      filters = [
        filter(%{
          "operator" => "is_not_empty",
          "property" => "Examflow - sprints",
          "propertyType" => "relation"
        })
      ]

      assert {%{}, [warning]} = FilterSolver.solve(filters, schema())
      assert warning =~ "is_not_empty"
    end

    test "enum_is_not with a single option warns" do
      filters = [
        filter(%{
          "operator" => "enum_is_not",
          "property" => "Only*",
          "propertyType" => "select",
          "value" => %{"type" => "exact", "value" => "Solo"}
        })
      ]

      assert {%{}, [warning]} = FilterSolver.solve(filters, schema())
      assert warning =~ "Only*"
    end

    test "unknown operator warns" do
      filters = [
        filter(%{"operator" => "weird_op", "property" => "Team*", "propertyType" => "select"})
      ]

      assert {%{}, [warning]} = FilterSolver.solve(filters, schema())
      assert warning =~ "weird_op"
    end
  end

  describe "solve/2 — multiple filters" do
    test "combines several satisfiable filters" do
      url = "https://app.notion.com/p/abc"

      filters = [
        filter(%{
          "operator" => "enum_is",
          "property" => "Team*",
          "value" => %{"type" => "exact", "value" => "ExamFlow"}
        }),
        filter(%{
          "operator" => "relation_contains",
          "property" => "Examflow - sprints",
          "value" => %{"type" => "exact", "value" => url}
        })
      ]

      {props, warnings} = FilterSolver.solve(filters, schema())
      assert warnings == []
      assert props["Team*"] == "ExamFlow"
      assert Jason.decode!(props["Examflow - sprints"]) == [url]
    end

    test "conflicting filters on the same property warn and last wins" do
      filters = [
        filter(%{
          "operator" => "enum_is",
          "property" => "Team*",
          "value" => %{"type" => "exact", "value" => "ExamFlow"}
        }),
        filter(%{
          "operator" => "enum_is",
          "property" => "Team*",
          "value" => %{"type" => "exact", "value" => "ScaleOps"}
        })
      ]

      assert {%{"Team*" => "ScaleOps"}, [warning]} = FilterSolver.solve(filters, schema())
      assert warning =~ "Conflicting"
    end
  end
end
