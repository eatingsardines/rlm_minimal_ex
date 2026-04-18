defmodule RlmMinimalEx.EnvironmentTest do
  use ExUnit.Case, async: true

  alias RlmMinimalEx.Environment

  setup do
    context = """
    alpha
    beta
    sentinel token: ORCHID-9137-DELTA
    omega
    """

    {:ok, env} =
      Environment.start_link(
        context: context,
        query: "What is the sentinel token?",
        lane: :workspace
      )

    assert {:ok, "Stored 'notes' (23 bytes)"} =
             Environment.execute(env, :write_var, %{
               "name" => "notes",
               "value" => "chunk summary goes here"
             })

    %{env: env, context: context}
  end

  test "read_text_range returns the requested substring", %{env: env, context: context} do
    [prefix, _rest] = String.split(context, "sentinel", parts: 2)
    offset = String.length(prefix)

    assert {:ok, "sentinel token: ORCHID-9137-DELTA"} =
             Environment.execute(env, :read_text_range, %{
               "source" => "context",
               "offset" => offset,
               "length" => String.length("sentinel token: ORCHID-9137-DELTA")
             })
  end

  test "slice_text returns the stored content and keeps the target var", %{env: env} do
    assert {:ok, content} =
             Environment.execute(env, :slice_text, %{
               "source" => "context",
               "offset" => 6,
               "length" => 18,
               "target" => "focus_chunk"
             })

    assert content ==
             "Stored 'focus_chunk' (18 chars) from 'context'\nContent:\nbeta\nsentinel toke"

    assert {:ok, "beta\nsentinel toke"} =
             Environment.execute(env, :read_text_range, %{
               "source" => "focus_chunk",
               "offset" => 0,
               "length" => 18
             })
  end

  test "read_text_range validates missing vars and offsets", %{env: env} do
    assert {:error, "Variable 'missing' not found"} =
             Environment.execute(env, :read_text_range, %{
               "source" => "missing",
               "offset" => 0,
               "length" => 10
             })

    assert {:error, "offset must be a non-negative integer"} =
             Environment.execute(env, :read_text_range, %{
               "source" => "context",
               "offset" => -1,
               "length" => 10
             })
  end

  test "read_lines returns numbered inclusive line ranges", %{env: env} do
    assert {:ok, content} =
             Environment.execute(env, :read_lines, %{
               "source" => "context",
               "start_line" => 2,
               "end_line" => 3
             })

    assert content == "L2: beta\nL3: sentinel token: ORCHID-9137-DELTA"
  end

  test "read_lines validates line ranges", %{env: env} do
    assert {:error, "start_line must be <= end_line"} =
             Environment.execute(env, :read_lines, %{
               "source" => "context",
               "start_line" => 3,
               "end_line" => 2
             })
  end

  test "write_scratchpad is allowed in read_only lane" do
    {:ok, env} =
      Environment.start_link(
        context: "ctx",
        query: "q",
        lane: :read_only
      )

    assert {:ok, "Stored scratch 'summary' as 'scratch:summary' (11 bytes)"} =
             Environment.execute(env, :write_scratchpad, %{
               "name" => "summary",
               "value" => "hello world"
             })

    assert {:ok, "scratch:summary = hello world"} =
             Environment.execute(env, :read_var, %{"name" => "scratch:summary"})
  end

  test "list_vars shows stored variable metadata", %{env: env} do
    assert {:ok, content} = Environment.execute(env, :list_vars, %{})

    assert content =~ "context (type=string,"
    assert content =~ "query (type=string,"
    assert content =~ "notes (type=string, size=23 bytes)"
  end

  test "describe_var returns metadata and preview", %{env: env} do
    assert {:ok, content} = Environment.execute(env, :describe_var, %{"name" => "notes"})

    assert content =~ "name: notes"
    assert content =~ "type: string"
    assert content =~ "size_bytes: 23"
    assert content =~ "preview: chunk summary goes here"
  end

  test "describe_var includes scratchpad entries written in read_only lane" do
    {:ok, env} =
      Environment.start_link(
        context: "ctx",
        query: "q",
        lane: :read_only
      )

    assert {:ok, _content} =
             Environment.execute(env, :write_scratchpad, %{
               "name" => "summary",
               "value" => "hello world"
             })

    assert {:ok, content} =
             Environment.execute(env, :describe_var, %{"name" => "scratch:summary"})

    assert content =~ "name: scratch:summary"
    assert content =~ "type: string"
    assert content =~ "size_bytes: 11"
    assert content =~ "preview: hello world"
  end

  test "describe_var returns an error for unknown vars", %{env: env} do
    assert {:error, "Variable 'missing' not found"} =
             Environment.execute(env, :describe_var, %{"name" => "missing"})
  end
end
