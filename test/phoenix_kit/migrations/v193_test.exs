defmodule PhoenixKit.Migrations.Postgres.V193Test do
  @moduledoc """
  V193's spend-cap indexes, run as real SQL, and proof that the query shape
  `phoenix_kit_ai`'s caps use can actually reach them.

  The second half is the point. A partial index is only used when Postgres can
  prove the query's condition implies the index's, and that proof fails for a
  bound `status = $1` once a prepared statement goes generic — the index then
  silently drops out of the plan. So this pins the query shape as well as the
  index: the status must stay a literal.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V193
  alias PhoenixKit.Test.Repo

  @indexes ~w(phoenix_kit_ai_requests_endpoint_spend_idx phoenix_kit_ai_requests_user_spend_idx)

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)

  defp present_indexes do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1)",
        [@indexes]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp marker do
    %{rows: [[marker]]} = Repo.query!("SELECT obj_description('phoenix_kit'::regclass)")
    marker
  end

  # The question is whether the spend-cap query CAN use the partial index —
  # not which of several equally cheap indexes the planner happens to pick for
  # a test-sized table (with a random id every candidate is estimated at one
  # row, and the choice between them is arbitrary). So the other indexes on
  # these columns are dropped inside the test's transaction (the sandbox
  # rolls the DROP back), sequential and bitmap scans are switched off, and
  # the plan must name the spend index. The seeded, analysed log keeps the
  # estimates realistic: a fortnight of history, one request in five failed.
  @competing_indexes ~w(phoenix_kit_ai_requests_endpoint_uuid_idx
                        phoenix_kit_ai_requests_user_uuid_idx
                        phoenix_kit_ai_requests_inserted_at_idx
                        phoenix_kit_ai_requests_status_idx)

  defp prepare_planner! do
    Repo.query!("""
    INSERT INTO phoenix_kit_ai_requests
      (status, cost_cents, endpoint_uuid, user_uuid, inserted_at, updated_at)
    SELECT
      CASE WHEN g % 5 = 0 THEN 'error' ELSE 'success' END,
      g % 97,
      NULL,
      NULL,
      now() - (g || ' minutes')::interval,
      now()
    FROM generate_series(1, 20000) AS g
    """)

    Repo.query!("ANALYZE phoenix_kit_ai_requests")
    Enum.each(@competing_indexes, &Repo.query!("DROP INDEX IF EXISTS #{&1}"))
    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_bitmapscan = off")
  end

  defp plan(sql, params) do
    prepare_planner!()
    %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
    rows |> List.flatten() |> Enum.join("\n")
  end

  # The same query with the status bound, planned the way a prepared
  # statement is once Postgres switches it to a generic plan.
  defp generic_plan(sql, params) do
    prepare_planner!()
    Repo.query!("SET LOCAL plan_cache_mode = force_generic_plan")
    Repo.query!("PREPARE v193_spend_probe AS " <> sql)

    try do
      args = Enum.map_join(params, ", ", &"'#{&1}'")
      %{rows: rows} = Repo.query!("EXPLAIN EXECUTE v193_spend_probe(#{args})")
      rows |> List.flatten() |> Enum.join("\n")
    after
      Repo.query!("DEALLOCATE v193_spend_probe")
    end
  end

  test "down drops both indexes, up puts them back, and each stamps its marker" do
    run(V193.down_statements("public."))
    assert present_indexes() == []
    assert marker() == "192"

    run(V193.up_statements("public."))
    assert present_indexes() == Enum.sort(@indexes)
    assert marker() == "193"
  end

  test "up leaves the connection's lock_timeout as it found it" do
    %{rows: [[before]]} = Repo.query!("SHOW lock_timeout")
    run(V193.up_statements("public."))
    assert %{rows: [[^before]]} = Repo.query!("SHOW lock_timeout")
  end

  test "up is re-runnable" do
    run(V193.up_statements("public."))
    run(V193.up_statements("public."))
    assert present_indexes() == Enum.sort(@indexes)
  end

  describe "the spend-cap query reaches the index" do
    @since_sql "now() - interval '1 day'"

    test "per endpoint, with the status as a literal" do
      sql = """
      SELECT coalesce(sum(cost_cents), 0) FROM phoenix_kit_ai_requests
      WHERE endpoint_uuid = $1 AND inserted_at >= #{@since_sql} AND status = 'success'
      """

      assert plan(sql, [Ecto.UUID.dump!(Ecto.UUID.generate())]) =~
               "phoenix_kit_ai_requests_endpoint_spend_idx"
    end

    test "per user, with the status as a literal" do
      sql = """
      SELECT coalesce(sum(cost_cents), 0) FROM phoenix_kit_ai_requests
      WHERE user_uuid = $1 AND inserted_at >= #{@since_sql} AND status = 'success'
      """

      assert plan(sql, [Ecto.UUID.dump!(Ecto.UUID.generate())]) =~
               "phoenix_kit_ai_requests_user_spend_idx"
    end

    test "a bound status loses the index once the plan goes generic" do
      sql = """
      SELECT coalesce(sum(cost_cents), 0) FROM phoenix_kit_ai_requests
      WHERE endpoint_uuid = $1 AND inserted_at >= #{@since_sql} AND status = $2
      """

      refute generic_plan(sql, [Ecto.UUID.generate(), "success"]) =~ "spend_idx"
    end
  end
end
