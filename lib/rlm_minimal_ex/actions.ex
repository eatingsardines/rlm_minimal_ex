defmodule RlmMinimalEx.Actions do
  @moduledoc """
  Defines the typed action schema exposed to the model.
  """

  @actions [
    %{
      name: :read_var,
      executor: :environment,
      lane: :read_only,
      description: "Read a variable from the environment",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Variable name to read"}
        },
        "required" => ["name"]
      }
    },
    %{
      name: :write_var,
      executor: :environment,
      lane: :workspace,
      description: "Store a value in the environment",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Variable name to write"},
          "value" => %{"type" => "string", "description" => "Value to store"}
        },
        "required" => ["name", "value"]
      }
    },
    %{
      name: :write_scratchpad,
      executor: :environment,
      lane: :read_only,
      description: "Store intermediate text in the scratchpad namespace",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Scratch variable name"},
          "value" => %{"type" => "string", "description" => "Scratch value to store"}
        },
        "required" => ["name", "value"]
      }
    },
    %{
      name: :slice_text,
      executor: :environment,
      lane: :read_only,
      description:
        "Extract a substring from a variable by character offset and length, storing and returning the result",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "source" => %{"type" => "string", "description" => "Source variable name"},
          "offset" => %{"type" => "integer", "description" => "Character offset (0-based)"},
          "length" => %{"type" => "integer", "description" => "Number of characters to extract"},
          "target" => %{
            "type" => "string",
            "description" => "Target variable name for the result"
          }
        },
        "required" => ["source", "offset", "length", "target"]
      }
    },
    %{
      name: :read_text_range,
      executor: :environment,
      lane: :read_only,
      description: "Read a character range from a stored string variable",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "source" => %{"type" => "string", "description" => "Source variable name"},
          "offset" => %{"type" => "integer", "description" => "Character offset (0-based)"},
          "length" => %{"type" => "integer", "description" => "Number of characters to read"}
        },
        "required" => ["source", "offset", "length"]
      }
    },
    %{
      name: :read_lines,
      executor: :environment,
      lane: :read_only,
      description: "Read an inclusive line range from a stored string variable",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "source" => %{"type" => "string", "description" => "Source variable name"},
          "start_line" => %{"type" => "integer", "description" => "First line number (1-based)"},
          "end_line" => %{"type" => "integer", "description" => "Last line number (1-based)"}
        },
        "required" => ["source", "start_line", "end_line"]
      }
    },
    %{
      name: :search_context,
      executor: :environment,
      lane: :read_only,
      description:
        "Search the context for lines matching a query string, returning matching lines with numbers",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search string"},
          "top_k" => %{
            "type" => "integer",
            "description" => "Maximum number of results (default 10)",
            "default" => 10
          }
        },
        "required" => ["query"]
      }
    },
    %{
      name: :list_vars,
      executor: :environment,
      lane: :read_only,
      description: "List stored variables with type and size metadata",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      }
    },
    %{
      name: :describe_var,
      executor: :environment,
      lane: :read_only,
      description: "Describe one stored variable including metadata and a short preview",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Variable name to describe"}
        },
        "required" => ["name"]
      }
    },
    %{
      name: :delegate_subtask,
      executor: :session,
      lane: :any,
      description: "Delegate a focused subtask to a one-shot worker",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task" => %{"type" => "string", "description" => "The subtask description"},
          "context_var" => %{
            "type" => "string",
            "description" => "Optional variable whose value becomes worker context"
          }
        },
        "required" => ["task"]
      }
    }
  ]

  @actions_by_name Map.new(@actions, &{&1.name, &1})
  @actions_by_string_name Map.new(@actions, &{Atom.to_string(&1.name), &1})

  @doc """
  Returns the full action definition list.
  """
  def all, do: @actions

  @doc """
  Renders the actions available in `lane` as provider tool definitions.
  """
  def to_tool_definitions(lane \\ :read_only) do
    @actions
    |> Enum.filter(&lane_allowed?(&1.lane, lane))
    |> Enum.map(&to_openai_tool/1)
  end

  @doc """
  Looks up an action definition by atom or string name.
  """
  def get(name) when is_atom(name) do
    Map.get(@actions_by_name, name)
  end

  def get(name) when is_binary(name) do
    Map.get(@actions_by_string_name, name)
  end

  defp lane_allowed?(:any, _lane), do: true
  defp lane_allowed?(action_lane, lane), do: action_lane == lane or lane == :workspace

  defp to_openai_tool(action) do
    %{
      "type" => "function",
      "function" => %{
        "name" => Atom.to_string(action.name),
        "description" => action.description,
        "parameters" => action.parameters
      }
    }
  end
end
