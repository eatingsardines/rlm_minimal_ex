defmodule RlmMinimalEx.ConfigurationTest do
  use ExUnit.Case, async: false

  alias RlmMinimalEx.{Env, Environment, Session}
  alias RlmMinimalEx.Trajectory.ModelCall

  setup do
    openai_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("RLM_MINIMAL_EX_MODEL")

    on_exit(fn ->
      restore_env("OPENAI_API_KEY", openai_key)
      restore_env("RLM_MINIMAL_EX_MODEL", model)
    end)

    :ok
  end

  test "load_dotenv reads quoted values from a local .env file" do
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("RLM_MINIMAL_EX_MODEL")

    in_tmp_dir(fn ->
      File.write!(".env", """
      OPENAI_API_KEY=\"test-key-from-dotenv\"
      RLM_MINIMAL_EX_MODEL='gpt-5.4-nano'
      """)

      assert :ok = Env.load_dotenv()
      assert System.get_env("OPENAI_API_KEY") == "test-key-from-dotenv"
      assert System.get_env("RLM_MINIMAL_EX_MODEL") == "gpt-5.4-nano"
    end)
  end

  test "load_dotenv leaves env untouched when .env is missing" do
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("RLM_MINIMAL_EX_MODEL")

    in_tmp_dir(fn ->
      refute File.exists?(".env")

      assert :ok = Env.load_dotenv()
      refute File.exists?(".env")
      assert System.get_env("OPENAI_API_KEY") == nil
      assert System.get_env("RLM_MINIMAL_EX_MODEL") == nil
    end)
  end

  test "load_dotenv does not override an existing shell env var" do
    System.put_env("OPENAI_API_KEY", "shell-key")

    in_tmp_dir(fn ->
      File.write!(".env", "OPENAI_API_KEY=dotenv-key\n")

      assert :ok = Env.load_dotenv()
      assert System.get_env("OPENAI_API_KEY") == "shell-key"
    end)
  end

  test "session defaults to gpt-5.4-nano when no override is configured" do
    System.delete_env("RLM_MINIMAL_EX_MODEL")

    {:ok, env} =
      Environment.start_link(
        context: "ctx",
        query: "q",
        lane: :read_only
      )

    parent = self()

    model_fn = fn model, _messages, _opts ->
      send(parent, {:model_seen, model})

      mc = %ModelCall{
        model: model,
        messages_in: 1,
        tools_offered: [],
        tool_calls_made: [],
        response_type: :text,
        input_tokens: 10,
        output_tokens: 5,
        duration_ms: 1
      }

      {:ok, :text, "done", mc}
    end

    {:ok, session} = Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 2)

    assert {:ok, "done", run} = Session.run(session, "q")
    assert run.status == :completed
    assert_receive {:model_seen, "gpt-5.4-nano"}
  end

  defp in_tmp_dir(fun) do
    tmp_dir = Path.join(System.tmp_dir!(), "rlm_minimal_ex_config_#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    previous = File.cwd!()

    try do
      File.cd!(tmp_dir, fun)
    after
      File.cd!(previous)
      File.rm_rf!(tmp_dir)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
