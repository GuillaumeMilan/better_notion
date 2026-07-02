defmodule BetterNotion.FilterSolver do
  @moduledoc """
  Derives page property values that satisfy a Notion view's `simpleFilters`,
  so a newly created page appears in the view.

  Pure module: takes the decoded `simpleFilters` list (each entry shaped
  `%{"filter" => %{...}, "id" => ...}`) and the data source `schema`
  (property name -> definition map), and returns `{properties, warnings}`.

  Property values use the same flat SQLite encoding as
  `BetterNotion.NotionMcpManager.update_properties/2` (select/status ->
  option name string, relation -> JSON-encoded array of page URLs, ...).

  Filters that cannot be auto-satisfied (person filters, relative relations,
  `is_not_empty`, unresolvable status groups, unsupported operators) are
  skipped and reported as human-readable warnings; the caller still creates
  the page.
  """

  @spec solve([map()], map()) :: {map(), [String.t()]}
  def solve(simple_filters, schema) when is_list(simple_filters) and is_map(schema) do
    {props, warnings} =
      Enum.reduce(simple_filters, {%{}, []}, fn entry, {props, warnings} ->
        case solve_filter(entry["filter"] || %{}, schema) do
          {:set, name, value} ->
            put_prop(props, warnings, name, value)

          {:set_and_warn, name, value, message} ->
            {p, w} = put_prop(props, warnings, name, value)
            {p, [message | w]}

          {:warn, message} ->
            {props, [message | warnings]}

          :noop ->
            {props, warnings}
        end
      end)

    {props, Enum.reverse(warnings)}
  end

  def solve(_simple_filters, _schema), do: {%{}, []}

  # --- Per-operator resolution ---

  # select / single enum "is"
  defp solve_filter(
         %{"operator" => "enum_is", "property" => name, "value" => %{"value" => value}},
         _schema
       )
       when is_binary(value) do
    {:set, name, value}
  end

  # select "is not" — pick any other option from the schema
  defp solve_filter(
         %{"operator" => "enum_is_not", "property" => name, "value" => %{"value" => excluded}},
         schema
       ) do
    case Enum.find(select_options(schema, name), &(&1 != excluded)) do
      nil -> {:warn, warn(name, "enum_is_not", "no alternative option available")}
      option -> {:set, name, option}
    end
  end

  # status "is" — prefer a concrete option, otherwise resolve a group
  defp solve_filter(
         %{"operator" => "status_is", "property" => name, "value" => entries},
         schema
       )
       when is_list(entries) do
    resolve_status_is(name, entries, schema)
  end

  # status "is not" — pick any status option not in the excluded set
  defp solve_filter(
         %{"operator" => "status_is_not", "property" => name, "value" => entries},
         schema
       )
       when is_list(entries) do
    excluded = status_excluded_names(entries, schema, name)

    case Enum.find(status_options(schema, name), &(&1 not in excluded)) do
      nil -> {:warn, warn(name, "status_is_not", "no allowed status option available")}
      option -> {:set, name, option}
    end
  end

  # relation "contains" an exact page
  defp solve_filter(
         %{
           "operator" => "relation_contains",
           "property" => name,
           "value" => %{"type" => "exact", "value" => url}
         },
         _schema
       )
       when is_binary(url) do
    {:set, name, Jason.encode!([url])}
  end

  defp solve_filter(
         %{
           "operator" => "relation_contains",
           "property" => name,
           "value" => %{"type" => "relative"}
         },
         _schema
       ) do
    {:warn, warn(name, "relation_contains", "relative relation values are not resolved")}
  end

  # relation "contains" a value we can't turn into a single concrete page
  # (e.g. a multi-page/list value, or a dynamic reference such as "current sprint")
  defp solve_filter(%{"operator" => "relation_contains", "property" => name}, _schema) do
    {:warn, warn(name, "relation_contains", "the relation value is not a single concrete page")}
  end

  # person filters are never resolved (per design)
  defp solve_filter(%{"operator" => "person_contains", "property" => name}, _schema) do
    {:warn, warn(name, "person_contains", "person filters are not resolved")}
  end

  # an empty property is satisfied by leaving it unset
  defp solve_filter(%{"operator" => "is_empty"}, _schema), do: :noop

  defp solve_filter(%{"operator" => "is_not_empty", "property" => name}, _schema) do
    {:warn, warn(name, "is_not_empty", "cannot fabricate a non-empty value")}
  end

  defp solve_filter(%{"operator" => operator, "property" => name}, _schema) do
    {:warn, warn(name, operator, "unsupported operator")}
  end

  defp solve_filter(_filter, _schema), do: {:warn, "Skipped an unrecognized filter."}

  # --- Status helpers ---

  defp resolve_status_is(name, entries, schema) do
    option = find_entry_value(entries, "is_option")

    cond do
      is_binary(option) ->
        {:set, name, option}

      true ->
        group = find_entry_value(entries, "is_group")

        case resolve_group(schema, name, group) do
          nil ->
            {:warn, warn(name, "status_is", "could not resolve status group #{inspect(group)}")}

          option_name ->
            {:set, name, option_name}
        end
    end
  end

  defp find_entry_value(entries, type) do
    Enum.find_value(entries, fn
      %{"type" => ^type, "value" => value} -> value
      _ -> nil
    end)
  end

  defp status_excluded_names(entries, schema, name) do
    Enum.flat_map(entries, fn
      %{"type" => "is_option", "value" => value} -> [value]
      %{"type" => "is_group", "value" => group} -> group_option_names(schema, name, group)
      _ -> []
    end)
  end

  # Resolves a status group (referenced in a filter by display name, e.g.
  # "In progress") to its first member option's name. Group keys in the schema
  # are normalized (e.g. "in_progress"), so we match on the normalized form.
  defp resolve_group(_schema, _name, nil), do: nil

  defp resolve_group(schema, name, group) do
    case List.first(group_options(schema, name, group)) do
      %{"name" => option_name} -> option_name
      _ -> nil
    end
  end

  defp group_option_names(schema, name, group) do
    schema
    |> group_options(name, group)
    |> Enum.map(& &1["name"])
  end

  defp group_options(schema, name, group) do
    groups = get_in(schema, [name, "groups"]) || %{}

    groups[group] ||
      Enum.find_value(groups, fn {key, options} ->
        if normalize(key) == normalize(group), do: options
      end) ||
      []
  end

  # --- Option helpers ---

  defp select_options(schema, name) do
    case get_in(schema, [name, "options"]) do
      options when is_list(options) -> Enum.map(options, & &1["name"])
      _ -> []
    end
  end

  defp status_options(schema, name) do
    case get_in(schema, [name, "groups"]) do
      groups when is_map(groups) ->
        groups |> Map.values() |> List.flatten() |> Enum.map(& &1["name"])

      _ ->
        select_options(schema, name)
    end
  end

  # --- Misc ---

  # Records a property value, warning when two filters disagree on the same key.
  defp put_prop(props, warnings, name, value) do
    case Map.fetch(props, name) do
      {:ok, existing} when existing != value ->
        {Map.put(props, name, value),
         ["Conflicting filters on \"#{name}\"; using \"#{value}\"." | warnings]}

      _ ->
        {Map.put(props, name, value), warnings}
    end
  end

  defp normalize(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize(value), do: value

  defp warn(name, operator, reason) do
    "Could not auto-satisfy filter #{operator} on \"#{name}\" (#{reason}). " <>
      "The \"#{name}\" property was left unset — set it manually with " <>
      "`better-notion update-properties <page> -p '{\"#{name}\": <value>}'` " <>
      "(inspect current values with `better-notion fetch-properties <page>`)."
  end
end
