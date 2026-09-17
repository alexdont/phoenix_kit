defmodule PhoenixKitWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://hexdocs.pm/gettext),
  your module gains a set of macros for translations, for example:

      import PhoenixKitWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://hexdocs.pm/gettext) for detailed usage.
  """

  # One module per locale, compiled in parallel. Unified, ~2.7k messages x
  # 8 locales became clauses of one giant function, which the compiler
  # handles superlinearly: a clean `mix compile --force` took 69s, 58s of
  # it on this file. Split: 20s. Elixir may still print "taking more than
  # 10s" for this file on a clean build; that is an informational notice.
  use Gettext.Backend, otp_app: :phoenix_kit, split_module_by: [:locale]
end
