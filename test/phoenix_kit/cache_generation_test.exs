defmodule PhoenixKit.CacheGenerationTest do
  @moduledoc """
  A miss-fill must not bring back a value that was invalidated after the miss.

  The reader misses, reads the old row, and the writer commits and
  invalidates before the reader's `put` arrives; an unconditional put then
  re-caches the replaced value until its TTL. `get_with_generation/3` hands
  the reader the cache's generation, every invalidation bumps it, and a put
  carrying an older one is dropped. No database: the cache alone.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Cache

  setup do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    :ok
  end

  defp start_cache(opts \\ []) do
    name = :"gen_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, Keyword.put(opts, :name, name)}, id: name)
    name
  end

  # Casts are asynchronous; any call waits until they have been handled.
  defp flush(cache), do: Cache.stats(cache)

  test "a fill from before an invalidation is dropped" do
    cache = start_cache()
    {:miss, generation} = miss(cache, "k")

    :ok = Cache.invalidate_now(cache, ["k"])
    :ok = Cache.put(cache, "k", "stale", if_generation: generation)
    flush(cache)

    assert Cache.get(cache, "k", :miss) == :miss
  end

  test "a fill with the current generation is written" do
    cache = start_cache()
    {:miss, generation} = miss(cache, "k")

    :ok = Cache.put(cache, "k", "fresh", if_generation: generation)
    flush(cache)

    assert Cache.get(cache, "k") == "fresh"
  end

  test "every kind of invalidation moves the generation" do
    cache = start_cache()

    for invalidate <- [
          fn -> Cache.invalidate(cache, "other") end,
          fn -> Cache.invalidate_multiple(cache, ["other"]) end,
          fn -> Cache.invalidate_now(cache, ["other"]) end,
          fn -> Cache.clear(cache) end,
          fn -> Cache.clear_by_prefix(cache, "oth") end
        ] do
      {:miss, generation} = miss(cache, "k")
      invalidate.()
      :ok = Cache.put(cache, "k", "stale", if_generation: generation)
      flush(cache)

      assert Cache.get(cache, "k", :miss) == :miss
    end
  end

  test "the batch forms follow the same rule" do
    cache = start_cache()
    {_found, generation} = Cache.get_multiple_with_generation(cache, ["a", "b"], %{})

    :ok = Cache.invalidate_now(cache, ["a"])
    :ok = Cache.put_multiple(cache, %{"a" => 1, "b" => 2}, if_generation: generation)
    flush(cache)

    assert Cache.get_multiple(cache, ["a", "b"], %{"a" => :miss, "b" => :miss}) == %{
             "a" => :miss,
             "b" => :miss
           }

    {_found, generation} = Cache.get_multiple_with_generation(cache, ["a", "b"], %{})
    :ok = Cache.put_multiple(cache, %{"a" => 1, "b" => 2}, if_generation: generation)
    flush(cache)
    assert Cache.get_multiple(cache, ["a", "b"]) == %{"a" => 1, "b" => 2}
  end

  test "a plain put is unconditional; a fill with no generation writes nothing" do
    cache = start_cache()
    :ok = Cache.invalidate_now(cache, ["k"])

    :ok = Cache.put(cache, "k", "plain")
    :ok = Cache.put(cache, "j", "unknown", if_generation: nil)
    :ok = Cache.put_multiple(cache, %{"i" => "unknown"}, if_generation: nil)
    flush(cache)

    assert Cache.get(cache, "k") == "plain"
    assert Cache.get(cache, "j", :miss) == :miss
    assert Cache.get(cache, "i", :miss) == :miss
  end

  test "a cache that is not running answers a miss with no generation" do
    assert Cache.get_with_generation(:no_such_cache, "k", :miss) == {:miss, nil}

    assert Cache.get_multiple_with_generation(:no_such_cache, ["k"], %{"k" => :miss}) ==
             {%{"k" => :miss}, nil}
  end

  test "a warm keeps an invalidation that arrived while the warmer read" do
    # The warmer runs inside the cache process, and this one queues an
    # invalidation of the key it is about to return — what a write committing
    # during the warmer's database read does. The warm's own insert must land
    # before that invalidation is handled, not after it.
    warmer = fn ->
      GenServer.cast(self(), {:invalidate_multiple, ["k"]})
      %{"k" => "read before the write"}
    end

    cache = start_cache(warmer: warmer)
    flush(cache)
    :ok = Cache.warm(cache)
    flush(cache)

    assert Cache.get(cache, "k", :miss) == :miss
  end

  defp miss(cache, key) do
    case Cache.get_with_generation(cache, key, :miss) do
      {:miss, generation} when is_integer(generation) -> {:miss, generation}
    end
  end
end
