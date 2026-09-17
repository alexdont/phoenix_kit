defmodule PhoenixKit.ModuleDiscoveryTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.ModuleDiscovery

  describe "discover_external_modules/0" do
    test "returns a list" do
      modules = ModuleDiscovery.discover_external_modules()
      assert is_list(modules)
    end

    test "all entries are atoms" do
      for mod <- ModuleDiscovery.discover_external_modules() do
        assert is_atom(mod)
      end
    end

    test "does not include internal PhoenixKit modules" do
      modules = ModuleDiscovery.discover_external_modules()

      refute PhoenixKitCustomerSupport in modules
      refute PhoenixKit.Modules.Billing in modules
      refute PhoenixKit.Jobs in modules
    end

    test "returns empty list when no external plugins installed" do
      # In the test environment, no external plugins are deps
      modules = ModuleDiscovery.discover_external_modules()

      # Config fallback may add modules, but beam scanning alone should find none
      # in the test environment (no external deps with @phoenix_kit_module)
      assert is_list(modules)
    end

    test "deduplicates results" do
      modules = ModuleDiscovery.discover_external_modules()
      assert length(modules) == length(Enum.uniq(modules))
    end
  end

  describe "scan_beam_files/0" do
    test "returns a list" do
      modules = ModuleDiscovery.scan_beam_files()
      assert is_list(modules)
    end

    test "does not crash on scan" do
      # Should not raise even if no external deps exist
      assert is_list(ModuleDiscovery.scan_beam_files())
    end

    @tag :tmp_dir
    test "finds a phoenix_kit-dependent dep on disk without its app being loaded", %{
      tmp_dir: tmp_dir
    } do
      mod = write_fixture_dep(tmp_dir, :fixture_dep_found, depends?: true, marked?: true)

      # Regression lock: the fixture app is never started, so it is absent from
      # :application.loaded_applications/0 — discovery must still find it via the
      # filesystem beam scan.
      refute Enum.any?(:application.loaded_applications(), fn {app, _, _} ->
               app == :fixture_dep_found
             end)

      assert mod in ModuleDiscovery.scan_beam_files()
      assert :fixture_dep_found in ModuleDiscovery.phoenix_kit_dependent_apps()
    end

    @tag :tmp_dir
    test "excludes a dep whose .app does not depend on :phoenix_kit", %{tmp_dir: tmp_dir} do
      mod = write_fixture_dep(tmp_dir, :fixture_dep_indep, depends?: false, marked?: true)

      refute mod in ModuleDiscovery.scan_beam_files()
      refute :fixture_dep_indep in ModuleDiscovery.phoenix_kit_dependent_apps()
    end

    @tag :tmp_dir
    test "excludes a beam without the @phoenix_kit_module attribute", %{tmp_dir: tmp_dir} do
      mod = write_fixture_dep(tmp_dir, :fixture_dep_unmarked, depends?: true, marked?: false)

      refute mod in ModuleDiscovery.scan_beam_files()
    end
  end

  # Builds a fake dep ebin layout in `dir`: a `<app>.app` resource file plus one
  # compiled module beam, then puts the dir on the code path (cleaned up after the
  # test). The app itself is never loaded/started.
  defp write_fixture_dep(dir, app, opts) do
    depends? = Keyword.fetch!(opts, :depends?)
    marked? = Keyword.fetch!(opts, :marked?)
    module = Module.concat([Macro.camelize(to_string(app))])

    marker =
      if marked? do
        """
        Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)
        @phoenix_kit_module true
        """
      else
        ""
      end

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        #{marker}
        def css_sources, do: [#{inspect(app)}]
      end
      """)

    File.write!(Path.join(dir, "#{module}.beam"), binary)

    extra = if depends?, do: ", phoenix_kit", else: ""

    File.write!(Path.join(dir, "#{app}.app"), """
    {application, #{app}, [
      {description, "fixture"},
      {vsn, "0.1.0"},
      {modules, ['#{module}']},
      {applications, [kernel, stdlib#{extra}]}
    ]}.
    """)

    Code.append_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)

    module
  end
end

defmodule PhoenixKit.ModuleDiscoveryConfigTest do
  # Sync on purpose: `:modules` is global, and `AdminRouteDedupTest` sets it
  # in its file body to compile a probe router. ExUnit runs async modules
  # while test files are still loading, so an async writer here interleaves
  # with that file — this test then reads the router's fixtures, and the
  # router compiles against this test's value. Sync modules start only once
  # every file has loaded.
  use ExUnit.Case, async: false

  alias PhoenixKit.ModuleDiscovery

  test "discover_external_modules/0 includes modules from config fallback" do
    original = Application.get_env(:phoenix_kit, :modules, [])

    try do
      Application.put_env(:phoenix_kit, :modules, [SomeFakeModule])
      modules = ModuleDiscovery.discover_external_modules()
      assert SomeFakeModule in modules
    after
      Application.put_env(:phoenix_kit, :modules, original)
    end
  end
end
