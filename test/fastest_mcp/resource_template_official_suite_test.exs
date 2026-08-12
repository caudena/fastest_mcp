defmodule FastestMCP.ResourceTemplateOfficialSuiteTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Components.ResourceTemplate

  @fixtures Path.expand("../fixtures/uri_template", __DIR__)

  for fixture <- [
        "spec-examples.json",
        "spec-examples-by-section.json",
        "extended-tests.json"
      ] do
    @fixture fixture

    test "expands every positive case in #{@fixture}" do
      cases = fixture_cases(@fixture)
      assert cases != []

      Enum.each(cases, fn {group_name, variables, template, expected} ->
        {matcher, _variables, _query_variables} = ResourceTemplate.compile_matcher!(template)
        expansion = ResourceTemplate.expand_compiled(matcher, variables)
        accepted = List.wrap(expected)

        assert expansion in accepted,
               "#{@fixture}: #{group_name}: #{inspect(template)} expanded to " <>
                 "#{inspect(expansion)}, expected one of #{inspect(accepted)}"
      end)
    end
  end

  test "rejects every official failure case during compilation or expansion" do
    cases = fixture_cases("negative-tests.json")
    assert cases != []

    Enum.each(cases, fn {group_name, variables, template, expected} ->
      assert expected == false,
             "negative-tests.json: #{group_name}: unexpected expectation " <>
               inspect(expected)

      assert {:error, _reason} = compile_and_expand(template, variables),
             "negative-tests.json: #{group_name}: #{inspect(template)} was accepted"
    end)
  end

  defp compile_and_expand(template, variables) do
    try do
      {matcher, _variables, _query_variables} = ResourceTemplate.compile_matcher!(template)
      {:ok, ResourceTemplate.expand_compiled(matcher, variables)}
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp load_fixture(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> JSON.decode!()
  end

  defp fixture_cases(name) do
    Enum.flat_map(load_fixture(name), fn {group_name, group} ->
      variables = Map.fetch!(group, "variables")

      Enum.map(Map.fetch!(group, "testcases"), fn testcase ->
        [template, expected] = testcase
        {group_name, variables, template, expected}
      end)
    end)
  end
end
