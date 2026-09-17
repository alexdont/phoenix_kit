# Locale Routing: the Language Lives in the URL

PhoenixKit serves each language of a page at its own URL — `/et/products`,
`/ru/products` — and sets the page language from that URL on every
navigation. The default language may be served without a prefix when the site
is configured that way. **A session-based language is not supported, on
purpose.** This guide explains why, and how to move a session-locale app onto
the supported shape.

If you arrived here because the language switcher's links "don't work", this
is almost certainly the cause: the page is showing a language its URL does not
carry. In development the switcher logs a warning that points here.

## Why the URL, not the session

- **A link must mean one thing.** Someone sends a link to a colleague; the
  colleague must see the same language. With a session language the same URL
  shows different content to different people.
- **Search engines index URLs.** `hreflang` and canonical links point at URLs,
  and crawlers send no cookies. A page whose language comes from the session is
  indexed in one language for everyone. Google's own guidance is to use a
  distinct URL per language rather than cookies or browser settings.
- **Caches and CDNs key on the URL.** A session-varying page is either
  uncacheable or served in the wrong language.
- **Link previews fetch without cookies.** Chat apps and social cards would
  always show the default language.
- **PhoenixKit tried it.** A session fallback once existed and was removed
  after it overrode the language of URLs people had been sent.

The invariant is *a distinct, stable URL per language*. A subdomain per
language satisfies it just as well as a path segment.

## Migrating a session-locale app

1. **Put the locale in your routes.** Wrap the localized pages in a locale
   scope, next to the unprefixed one if your default language is prefixless:

   ```elixir
   scope "/", MyAppWeb do
     pipe_through :browser
     live "/products", ProductLive.Index   # default language
   end

   scope "/:locale", MyAppWeb do
     pipe_through :browser
     live "/products", ProductLive.Index   # every other language
   end
   ```

2. **Build links with the kit's helpers**, so they keep the current language:

   ```elixir
   PhoenixKit.Utils.Routes.path("/products")
   PhoenixKit.Utils.Routes.path("/products", locale: "et")
   ```

3. **Stop reading the language from the session** when rendering a page. Let
   the URL decide; PhoenixKit's `on_mount` hooks set Gettext from it.

4. **Keep the preference for the landing page only.** A saved preference or a
   cookie may choose where a bare `/` goes:

   ```elixir
   def home(conn, _params) do
     locale = get_session(conn, :preferred_locale) || "en"
     redirect(conn, to: PhoenixKit.Utils.Routes.path("/", locale: locale))
   end
   ```

   Once a URL carries a locale, the URL wins — never consult the preference on
   a URL that already has one. (That is exactly the bug the removed session
   fallback had.) If the redirect depends on the visitor, don't let a shared
   cache store it.

5. **Switching language is navigation.** The switcher links to the same page
   under the other locale. If you need your own switcher markup, build the
   links with `PhoenixKitWeb.Components.Core.LanguageSwitcher.locale_path/2`,
   which returns exactly what the component renders.

## What is deliberately not offered

- A "session locale mode".
- A switcher hook that can produce the same URL for every language.

Both would make PhoenixKit carry two routing models, and every URL it builds
— email links, sitemaps, social cards — would have to support both.
