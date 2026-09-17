defmodule PhoenixKit.ObanQueuesTest do
  @moduledoc """
  Declared Oban queues: core's own, each module's `oban_queues/0`, and the
  fallback entries core still writes for modules that do not declare yet.

  What the host relies on: every queue a job can be sent to ends up in its
  config, a limit the host set is never changed, a web-only node is left
  alone, and two modules that disagree are reported rather than silently
  merged.
  """
  # async: false — the updater tests swap the global Mix shell to capture its
  # messages, which would leak into any concurrently running test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mix.Tasks.PhoenixKit.Doctor
  alias PhoenixKit.Install.ObanConfig
  alias PhoenixKit.ObanQueues

  defmodule ImageModule do
    def oban_queues, do: [image_generation: [limit: 3, kind: :interactive], image_import: 2]
  end

  defmodule OtherImageModule do
    def oban_queues, do: [image_generation: 8]
  end

  defmodule SharingModule do
    def oban_queues, do: [image_generation: 3]
  end

  defmodule CatalogueLike do
    # Takes over a queue core used to write on its behalf, with its own number.
    def oban_queues, do: [catalogue_pdf: 4]
  end

  defmodule BrokenModule do
    def oban_queues, do: [{"Bad Name", 3}, zero: 0, fine: 1]
  end

  defmodule SilentModule do
  end

  defp names(specs), do: Enum.map(specs, & &1.name)

  describe "resolve/1" do
    test "core first, then modules, then the fallbacks no module took over" do
      {declared, []} = ObanQueues.resolve([ImageModule])

      assert names(declared) ==
               ~w(default file_processing scheduled_jobs sitemap notifications
                  image_generation image_import posts newsletters_delivery catalogue_pdf
                  shop_imports)a

      assert %{limit: 3, kind: :interactive, owner: ImageModule} =
               Enum.find(declared, &(&1.name == :image_generation))
    end

    test "a module without the callback declares nothing" do
      {declared, []} = ObanQueues.resolve([SilentModule])
      assert names(declared) == names(ObanQueues.declared([]))
    end

    test "a module that declares a fallback queue owns it, with its own limit, silently" do
      {declared, conflicts} = ObanQueues.resolve([CatalogueLike])

      assert conflicts == []

      assert [%{limit: 4, owner: CatalogueLike}] =
               Enum.filter(declared, &(&1.name == :catalogue_pdf))
    end

    test "two modules sharing a queue with the same limit is not a conflict" do
      {declared, conflicts} = ObanQueues.resolve([ImageModule, SharingModule])

      assert conflicts == []
      assert Enum.count(declared, &(&1.name == :image_generation)) == 1
    end

    test "different limits are a conflict; the first in a stable order wins" do
      {declared, [conflict]} = ObanQueues.resolve([OtherImageModule, ImageModule])

      # Sorted by module name, so the answer does not depend on scan order.
      assert %{limit: 3, owner: ImageModule} =
               Enum.find(declared, &(&1.name == :image_generation))

      assert conflict.kept.owner == ImageModule
      assert conflict.ignored.owner == OtherImageModule
      assert ObanQueues.describe_conflict(conflict) =~ "image_generation"

      assert {_same, [_]} = ObanQueues.resolve([ImageModule, OtherImageModule])
    end

    test "invalid declarations are dropped with a warning, the valid ones kept" do
      log =
        capture_log(fn ->
          {declared, []} = ObanQueues.resolve([BrokenModule])
          assert :fine in names(declared)
          refute :zero in names(declared)
        end)

      assert log =~ "invalid Oban queue declaration"
    end
  end

  describe "missing/2" do
    setup do
      %{declared: ObanQueues.declared([ImageModule])}
    end

    test "lists declared queues the config does not run", %{declared: declared} do
      config = [queues: [default: 10, file_processing: 20, image_generation: 5]]
      missing = config |> ObanQueues.missing(declared) |> names()

      assert :image_import in missing
      refute :image_generation in missing, "configured with another limit is still configured"
      refute :default in missing
    end

    test "the keyword form of a queue counts", %{declared: declared} do
      config = [queues: [default: [limit: 10]]]
      refute :default in names(ObanQueues.missing(config, declared))
    end

    test "a node that runs no queues is missing nothing", %{declared: declared} do
      assert ObanQueues.missing([queues: false], declared) == []
      assert ObanQueues.missing([queues: []], declared) == []
      assert ObanQueues.missing(nil, declared) == []
    end
  end

  describe "required/2 and the boot check" do
    setup do
      %{resolved: ObanQueues.resolve([ImageModule, CatalogueLike])}
    end

    test "a fallback queue is required only when its package is installed", %{
      resolved: {declared, _}
    } do
      nothing = ObanQueues.required(declared, fn _app -> false end) |> names()
      refute :posts in nothing
      refute :shop_imports in nothing
      assert :default in nothing, "core's own queues are always required"
      assert :image_generation in nothing, "a module's declared queues are always required"

      assert :catalogue_pdf in nothing,
             "a fallback a module took over is that module's queue, not a fallback"

      only_posts = ObanQueues.required(declared, &(&1 == :phoenix_kit_posts)) |> names()
      assert :posts in only_posts
      refute :newsletters_delivery in only_posts
    end

    test "the installer still writes every fallback", %{resolved: {declared, _}} do
      assert Enum.all?(~w(posts newsletters_delivery shop_imports)a, &(&1 in names(declared)))
    end

    test "the boot check names a missing fallback only for an installed package", %{
      resolved: resolved
    } do
      running = [default: 10, file_processing: 20, scheduled_jobs: 1, sitemap: 5]
      running = running ++ [notifications: 10, image_generation: 3, image_import: 2]
      running = running ++ [catalogue_pdf: 4]

      assert {[], []} = ObanQueues.boot_findings(running, resolved, fn _ -> false end)

      assert {[%{name: :newsletters_delivery}], []} =
               ObanQueues.boot_findings(running, resolved, &(&1 == :phoenix_kit_newsletters))
    end

    @tag :tmp_dir
    test "a package on the code path counts before it has been loaded", %{tmp_dir: dir} do
      # What a host's boot looks like early on: the dependency is there, but
      # nothing has loaded its application yet.
      File.write!(Path.join(dir, "phoenix_kit_newsletters.app"), """
      {application, phoenix_kit_newsletters,
       [{description, "fixture"}, {vsn, "0.0.1"}, {modules, []},
        {applications, [kernel, stdlib]}]}.
      """)

      Code.append_path(dir)

      on_exit(fn ->
        Application.unload(:phoenix_kit_newsletters)
        Code.delete_path(dir)
      end)

      assert Application.spec(:phoenix_kit_newsletters, :vsn) == nil

      {declared, _} = ObanQueues.resolve([])
      required = ObanQueues.required(declared) |> names()
      assert :newsletters_delivery in required
      refute :posts in required
    end

    test "by default, installed means the package is on the code path" do
      {declared, _} = ObanQueues.resolve([])
      # None of the four packages is a dependency of core's own suite.
      assert ObanQueues.required(declared) |> names() |> Enum.all?(&(&1 not in ~w(posts
             newsletters_delivery catalogue_pdf shop_imports)a))
    end
  end

  describe "the updater's backfill" do
    @host """
    config :my_app, Oban,
      repo: MyApp.Repo,
      queues: [
        default: 25,
        emails: 50
      ]
    """

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      %{declared: ObanQueues.declared([ImageModule])}
    end

    test "adds what is missing and parses", %{declared: declared} do
      updated = ObanConfig.ensure_declared_queues(@host, "my_app", declared)

      assert updated =~ ~r/image_generation:\s*3/
      assert updated =~ ~r/file_processing:\s*20/
      assert {:ok, _} = Code.string_to_quoted(updated)
    end

    test "never changes a limit the host set", %{declared: declared} do
      updated = ObanConfig.ensure_declared_queues(@host, "my_app", declared)

      assert updated =~ ~r/default:\s*25/
      refute updated =~ ~r/default:\s*10/
    end

    test "is idempotent", %{declared: declared} do
      once = ObanConfig.ensure_declared_queues(@host, "my_app", declared)
      assert ObanConfig.ensure_declared_queues(once, "my_app", declared) == once
    end

    test "leaves a node that runs no queues exactly as it is, quietly", %{declared: declared} do
      for queues <- ["false", "[]"] do
        web_only = """
        config :my_app, Oban,
          repo: MyApp.Repo,
          queues: #{queues}
        """

        assert ObanConfig.ensure_declared_queues(web_only, "my_app", declared) == web_only

        # One line saying why — not a "please add this manually" error for
        # every declared queue on a node that deliberately runs none.
        assert_received {:mix_shell, :info, [info]}
        assert info =~ "runs no queues"
        refute_received {:mix_shell, :error, _}
      end
    end

    test "another app's block listing a queue does not count for this app", %{declared: declared} do
      content = """
      config :other_app, Oban,
        queues: [
          notifications: 5,
          image_generation: 1
        ]

      #{@host}
      """

      updated = ObanConfig.ensure_declared_queues(content, "my_app", declared)
      [_other, mine] = String.split(updated, "config :my_app, Oban,")

      assert mine =~ ~r/notifications:\s*10/
      assert mine =~ ~r/image_generation:\s*3/
      assert {:ok, _} = Code.string_to_quoted(updated)
    end

    test "another app's disabled queues do not stop this app's backfill", %{declared: declared} do
      content = """
      config :other_app, Oban,
        queues: false

      #{@host}
      """

      assert ObanConfig.ensure_declared_queues(content, "my_app", declared) =~
               ~r/image_generation:\s*3/
    end
  end

  describe "the generated install block" do
    test "lists every declared queue, with who asked for it, and parses" do
      declared = ObanQueues.declared([ImageModule])
      lines = ObanConfig.generated_queue_lines(declared)

      assert {:ok, ast} = Code.string_to_quoted("[\n" <> lines <> "\n]")
      {list, _} = Code.eval_quoted(ast)

      assert Keyword.keys(list) == names(declared)
      assert list[:image_generation] == 3
      assert lines =~ "PhoenixKit.ObanQueuesTest.ImageModule, interactive"
    end
  end

  describe "the doctor's verdict" do
    setup do
      %{declared: ObanQueues.declared([ImageModule])}
    end

    test "warns about missing queues and says how to fix it", %{declared: declared} do
      assert {:warn, message} =
               Doctor.declared_queues_verdict([queues: [default: 10]], declared, [])

      assert message =~ "image_generation: 3"
      assert message =~ "mix phoenix_kit.update"
    end

    test "passes when everything declared is configured", %{declared: declared} do
      config = [queues: Enum.map(declared, &{&1.name, &1.limit})]
      assert {:pass, _} = Doctor.declared_queues_verdict(config, declared, [])
    end

    test "a config with no queues: key runs nothing, and says so", %{declared: declared} do
      assert {:warn, message} = Doctor.declared_queues_verdict([repo: SomeRepo], declared, [])
      assert message =~ "no queues: list"
      assert message =~ "image_generation: 3"
      assert message =~ "queues: false"
    end

    test "a web-only node passes, naming what its worker nodes need", %{declared: declared} do
      assert {:pass, message} = Doctor.declared_queues_verdict([queues: false], declared, [])
      assert message =~ "worker nodes"
    end

    test "conflicts are reported even when nothing is missing", %{declared: declared} do
      {_, conflicts} = ObanQueues.resolve([ImageModule, OtherImageModule])
      config = [queues: Enum.map(declared, &{&1.name, &1.limit})]

      assert {:warn, message} = Doctor.declared_queues_verdict(config, declared, conflicts)
      assert message =~ "image_generation"
    end
  end
end
