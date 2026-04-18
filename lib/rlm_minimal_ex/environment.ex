defmodule RlmMinimalEx.Environment do
  @moduledoc """
  Owns externalized state and environment-side action execution for a single run.

  The environment stores values such as `"context"` and `"query"` in an ETS
  table created per run. Reads stay cheap through ETS, while writes remain
  serialized through this process so lane policy and metadata stay consistent.
  """
  use GenServer

  defstruct [:run_id, :ets, :lane, :var_meta]

  @doc """
  Starts an environment process for a run.
  """
  def start_link(opts) do
    gen_opts =
      case opts[:run_id] do
        nil -> []
        run_id -> [name: {:via, Registry, {RlmMinimalEx.Registry, {:env, run_id}}}]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Executes an environment-owned action such as `read_var` or `search_context`.
  """
  def execute(pid, action_name, params) do
    GenServer.call(pid, {:execute, action_name, params}, :timer.seconds(30))
  end

  @doc """
  Returns the raw value of a stored variable.
  """
  def get_var(pid, name) do
    GenServer.call(pid, {:get_var, name})
  end

  @impl true
  def init(opts) do
    run_id = opts[:run_id] || make_ref()

    # Unnamed table avoids dynamic atom creation. `:protected` keeps writes
    # behind the environment boundary while still allowing cheap concurrent reads.
    table = :ets.new(:rlm_minimal_ex_env, [:set, :protected, read_concurrency: true])

    context = opts[:context]
    query = opts[:query]

    if context, do: :ets.insert(table, {"context", context})
    if query, do: :ets.insert(table, {"query", query})

    state = %__MODULE__{
      run_id: run_id,
      ets: table,
      lane: opts[:lane] || :read_only,
      var_meta: init_var_meta(context, query)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, action_name, params}, _from, state) do
    {result, state} = do_execute(action_name, params, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_var, name}, _from, state) do
    {:reply, ets_get(state.ets, name), state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.ets do
      try do
        :ets.delete(state.ets)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp do_execute(:read_var, %{"name" => name}, state) do
    case ets_get(state.ets, name) do
      nil -> {{:error, "Variable '#{name}' not found"}, state}
      value -> {{:ok, "#{name} = #{preview(value)}"}, state}
    end
  end

  defp do_execute(:write_var, %{"name" => name, "value" => value}, state) do
    if state.lane == :read_only do
      {{:error, "Write not permitted in read_only lane"}, state}
    else
      state = put_var(state, name, value)
      {{:ok, "Stored '#{name}' (#{byte_size_of(value)} bytes)"}, state}
    end
  end

  defp do_execute(:write_scratchpad, %{"name" => name, "value" => value}, state) do
    key = scratchpad_key(name)

    state =
      put_var(state, key, value, %{
        scope: :scratch,
        scratch_name: name
      })

    {{:ok, "Stored scratch '#{name}' as '#{key}' (#{byte_size_of(value)} bytes)"}, state}
  end

  defp do_execute(
         :slice_text,
         %{"source" => source, "offset" => offset, "length" => len, "target" => target},
         state
       ) do
    case ets_get(state.ets, source) do
      nil ->
        {{:error, "Variable '#{source}' not found"}, state}

      value when is_binary(value) ->
        sliced = String.slice(value, offset, len)
        :ets.insert(state.ets, {target, sliced})

        meta =
          Map.put(state.var_meta, target, %{
            type: :string,
            created_at: DateTime.utc_now(),
            size: byte_size(sliced)
          })

        content = """
        Stored '#{target}' (#{String.length(sliced)} chars) from '#{source}'
        Content:
        #{sliced}
        """

        {{:ok, String.trim(content)}, %{state | var_meta: meta}}

      _other ->
        {{:error, "Variable '#{source}' is not a string"}, state}
    end
  end

  defp do_execute(
         :read_text_range,
         %{"source" => source, "offset" => offset, "length" => len},
         state
       ) do
    with {:ok, value} <- fetch_string_var(state, source),
         {:ok, offset} <- validate_non_negative_integer(offset, "offset"),
         {:ok, len} <- validate_non_negative_integer(len, "length") do
      chunk = String.slice(value, offset, len) || ""
      {{:ok, chunk}, state}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  defp do_execute(
         :read_lines,
         %{"source" => source, "start_line" => start_line, "end_line" => end_line},
         state
       ) do
    with {:ok, value} <- fetch_string_var(state, source),
         {:ok, start_line} <- validate_positive_integer(start_line, "start_line"),
         {:ok, end_line} <- validate_positive_integer(end_line, "end_line"),
         :ok <- validate_line_range(start_line, end_line) do
      lines =
        value
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {_line, number} -> number >= start_line and number <= end_line end)
        |> Enum.map_join("\n", fn {line, number} -> "L#{number}: #{line}" end)

      content =
        if lines == "" do
          "No lines found in range #{start_line}-#{end_line} for '#{source}'"
        else
          lines
        end

      {{:ok, content}, state}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  defp do_execute(:search_context, %{"query" => query} = params, state) do
    top_k = params["top_k"] || 10

    case ets_get(state.ets, "context") do
      nil ->
        {{:error, "No context loaded"}, state}

      context when is_binary(context) ->
        query_down = String.downcase(query)

        results =
          context
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _i} ->
            String.contains?(String.downcase(line), query_down)
          end)
          |> Enum.take(top_k)
          |> Enum.map_join("\n", fn {line, i} -> "L#{i}: #{line}" end)

        if results == "" do
          {{:ok, "No matches found for '#{query}'"}, state}
        else
          {{:ok, results}, state}
        end

      _other ->
        {{:error, "Context is not searchable text"}, state}
    end
  end

  defp do_execute(:list_vars, _params, state) do
    listing =
      state.var_meta
      |> Enum.sort_by(fn {name, _meta} -> name end)
      |> Enum.map_join("\n", fn {name, meta} ->
        "#{name} (type=#{meta.type}, size=#{meta.size} bytes)"
      end)

    content =
      if listing == "" do
        "No variables stored"
      else
        listing
      end

    {{:ok, content}, state}
  end

  defp do_execute(:describe_var, %{"name" => name}, state) do
    case {Map.get(state.var_meta, name), ets_get(state.ets, name)} do
      {nil, _} ->
        {{:error, "Variable '#{name}' not found"}, state}

      {meta, value} ->
        content = """
        name: #{name}
        type: #{meta.type}
        size_bytes: #{meta.size}
        created_at: #{DateTime.to_iso8601(meta.created_at)}
        preview: #{preview(value)}
        """

        {{:ok, String.trim(content)}, state}
    end
  end

  defp do_execute(action, _params, state) do
    {{:error, "Unknown environment action: #{action}"}, state}
  end

  defp ets_get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp preview(value) when is_binary(value) do
    if String.length(value) > 200 do
      String.slice(value, 0, 200) <> "... (#{String.length(value)} chars)"
    else
      value
    end
  end

  defp preview(value), do: inspect(value, limit: 5, printable_limit: 200)

  defp fetch_string_var(state, name) do
    case ets_get(state.ets, name) do
      nil -> {:error, "Variable '#{name}' not found"}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, "Variable '#{name}' is not a string"}
    end
  end

  defp put_var(state, name, value, extra_meta \\ %{}) do
    :ets.insert(state.ets, {name, value})

    meta =
      Map.merge(
        %{
          type: type_of(value),
          created_at: DateTime.utc_now(),
          size: byte_size_of(value)
        },
        extra_meta
      )

    %{state | var_meta: Map.put(state.var_meta, name, meta)}
  end

  defp scratchpad_key(name) when is_binary(name) do
    if String.starts_with?(name, "scratch:") do
      name
    else
      "scratch:" <> name
    end
  end

  defp validate_non_negative_integer(value, _field) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp validate_non_negative_integer(_value, field),
    do: {:error, "#{field} must be a non-negative integer"}

  defp validate_positive_integer(value, _field) when is_integer(value) and value >= 1,
    do: {:ok, value}

  defp validate_positive_integer(_value, field),
    do: {:error, "#{field} must be a positive integer"}

  defp validate_line_range(start_line, end_line) when start_line <= end_line, do: :ok
  defp validate_line_range(_start_line, _end_line), do: {:error, "start_line must be <= end_line"}

  defp type_of(v) when is_binary(v), do: :string
  defp type_of(v) when is_list(v), do: :list
  defp type_of(v) when is_map(v), do: :map
  defp type_of(_), do: :other

  defp byte_size_of(v) when is_binary(v), do: byte_size(v)
  defp byte_size_of(v), do: v |> :erlang.term_to_binary() |> byte_size()

  defp init_var_meta(context, query) do
    meta = %{}

    meta =
      if context,
        do:
          Map.put(meta, "context", %{
            type: type_of(context),
            created_at: DateTime.utc_now(),
            size: byte_size_of(context)
          }),
        else: meta

    if query,
      do:
        Map.put(meta, "query", %{
          type: :string,
          created_at: DateTime.utc_now(),
          size: byte_size_of(query)
        }),
      else: meta
  end
end
