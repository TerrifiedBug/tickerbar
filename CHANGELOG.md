# Changelog

All notable changes to TickerBar will be documented in this file.

## [Unreleased]

## [1.5.2] - 2026-09-23

### Fixed
- Menu bar text is legible on a dark menu bar while macOS is in Light mode (#24). The menu bar's appearance follows the wallpaper rather than the system setting, but the text color was resolved against the app's (system) appearance, so a Light-mode Mac with a dark wallpaper drew black text on a dark bar. Colors now follow the menu bar itself, and still turn dark on a light menu bar.

## [1.5.1] - 2026-08-16

### Fixed
- Quotes keep refreshing after a market closes. Timer refreshes were skipped whenever no watchlist session was live, but that decision read the market state cached by the last fetch — and only a fetch could update it. The first closed session therefore froze the app for the rest of its life: it never noticed the market reopening, so the menu bar kept showing a price from hours or days earlier until TickerBar was relaunched. A closed market now only slows the cadence to every 15 minutes rather than stopping refreshes, so reopenings, holidays and half-days are all picked up without help.
- Waking the Mac refreshes straight away, instead of showing the prices from before it went to sleep until the next scheduled tick.
- The watchlist tops up quotes that have aged past one refresh interval as its panel appears, so what you open is not showing stale numbers.
- A failed refresh is retried after 5, 15 and 60 seconds before falling back to the normal cadence. The refresh moments after wake usually fails because the network isn't up yet, and that attempt used to cost a whole interval.
- Refresh and rotation now run in the common run loop modes, so both keep ticking while the watchlist panel is open. Both also carry a wakeup tolerance, letting macOS coalesce them with other timers instead of waking the CPU on their own.

## [1.5.0] - 2026-08-02

### Changed
- Releases are now signed with an Apple Developer ID certificate and notarized by Apple. macOS no longer blocks the first launch, so the `xattr -dr com.apple.quarantine` workaround is gone.
- Signing is now done by `xcodebuild` archive and export instead of `codesign --deep`. Sparkle documents `--deep` as a common source of signing errors, because the XPC services it bundles have different requirements from the rest of the app. Sparkle's framework, updater and helper tools are now signed inside-out.
- The repository moved to `TerrifiedBug/tickerbar` and the release asset is now `tickerbar.zip`. GitHub redirects the old paths, so existing installs keep updating.

### Removed
- Dropped the App Sandbox entitlements and the sandbox-only Sparkle installer service. No released build was ever sandboxed, because the old ad-hoc signing step applied no entitlements at all. Signing correctly would have switched the sandbox on for the first time and moved preferences into `~/Library/Containers`, losing every existing watchlist, holding and alert. TickerBar ships through Developer ID rather than the App Store, where the sandbox is optional.

## [1.4.1] - 2026-07-13

### Fixed
- Display-name editing now stays inside the menu-bar panel, so its controls respond to mouse clicks instead of dismissing the panel.

## [1.4.0] - 2026-07-13

### Added
- Custom display names for watchlist stocks, replacing ticker and currency symbols in the menu bar and watchlist for more discreet tracking.
- Optional live pre-market, after-hours, and overnight prices with extended-session sparklines, compact watchlist indicators, and labeled details when Yahoo provides the data.
- Expandable portfolio summaries now show grouped position values and returns, while each stock’s details include its individual purchase and RSU lots.

### Fixed
- Stock-row detail chevrons now have a larger click target, so expanding a row no longer requires pixel-perfect accuracy.
- The “Markets Closed” banner now remains visible during pre-market, after-hours, and overnight sessions, even when live extended-hours prices are enabled.

## [1.3.1] - 2026-06-27

### Fixed
- In-app updates now work for Homebrew installs too. Previously the app disabled the Sparkle updater whenever it detected a Homebrew install and told you to "update with `brew upgrade`"; now "Check for Updates" and automatic checks always work.

### Changed
- Distribution moved to the shared `terrifiedbug/tap` Homebrew tap: `brew install --cask terrifiedbug/tap/tickerbar`. The cask sets `auto_updates true` so Homebrew defers to the in-app updater.

## [1.3.0] - 2026-06-18

### Added
- Multi-lot holdings — track multiple RSU (vested, value-only) and purchase lots per stock; add via "Add RSUs…" / "Add Purchase…" in the right-click menu. Cost basis is now optional, so awarded stock can be tracked for value without a purchase price
- Export & import of your watchlist, holdings, alerts, and base currency as JSON (Settings ▸ Backup)
- Percent-change and recurring price alerts, alongside the existing absolute-price one-shot alerts
- Expandable watchlist rows showing 52-week range, pre/post-market, and day range inline (previously hover-only)
- Home-screen WidgetKit widget showing live prices
- Notice when a holding is excluded from the portfolio total because its exchange rate hasn't loaded yet
- `LICENSE` file (MIT)

### Fixed
- Yahoo Finance requests are now built with `URLComponents`, fixing intermittent authentication failures when the session crumb contained a `+`, and allowing index symbols such as `^GSPC` to resolve
- A missing exchange rate no longer silently values a foreign holding 1:1 (e.g. a JPY holding counted ~150× too high) — such holdings are excluded from the total with a notice instead
- Market-hours detection now accounts for the Tokyo and Hong Kong/Shanghai lunch breaks, and prefers Yahoo's reported market state when available
- The rotating menu-bar item now stays in sync with the rotation index
- Corrected the README build command and removed a stale settings entry

### Changed
- Refresh now uses two batched requests (quote + spark) instead of one request per symbol, falling back to the per-symbol path when needed
- Internal: `StockService` split into focused units (networking, portfolio math, currency), with tests isolated from real preferences and CI running build + tests on every change

## [1.2.3] - 2026-06-17

### Fixed
- Dropdown no longer leaves a large empty space after collapsing the inline Settings panel — the popover now resizes from the content height SwiftUI has actually committed (via GeometryReader) instead of the host view's lagging `fittingSize`, which never updated on collapse

## [1.2.2] - 2026-06-05

### Fixed
- Menu bar text size now also applies to the compact (two-line) layout, not just normal mode
- Dropdown no longer leaves an empty gap above its content after expanding and collapsing Settings — the popover now re-fits to its content height

## [1.2.1] - 2026-06-05

### Added
- Menu bar text size setting (normal mode) — choose 10–16pt; defaults to the original 10pt
- Solid dropdown background option for readability over busy wallpapers

### Fixed
- Menu bar dropdown no longer floats with an empty gap above its content
- Menu bar text is now legible on light menu bars (Light Mode) — uses adaptive system colors instead of hardcoded white
- Transient Yahoo Finance API errors now auto-retry (re-authenticate) and retain the last known prices instead of blanking the menu bar

## [1.2.0] - 2026-02-20

### Added
- Portfolio tracking with cost basis — track shares owned and average buy price per stock
- Unified portfolio summary with automatic currency conversion to your chosen base currency
- Base currency setting (USD, GBP, EUR, JPY, CAD, AUD, CHF) in Settings
- Pre-market and after-hours prices via Yahoo Finance v7/quote API
- 52-week high/low data
- Rich tooltips on hover — day range, 52-week range, pre/post market prices, holdings details, market state
- Briefcase icon on stocks with holdings
- Holdings management in right-click context menu (add/edit/remove)
- Exchange rate fetching via Yahoo Finance FX pairs (e.g. GBPUSD=X)

### Fixed
- GBX (pence) and ILA (agorot) sub-unit currencies now display correctly in pounds/shekels
- Price alerts use correct display price for sub-unit currencies
- Holdings cost basis defaults to correct display price for sub-unit stocks

## [1.1.1] - 2026-02-20

### Added
- Auto-detect Homebrew installation — disables Sparkle updates and shows `brew upgrade` hint in settings

### Fixed
- CI release workflow appcast.xml conflict on re-runs

### Removed
- "Only refresh during market hours" toggle — handled automatically

## [1.1.0] - 2026-02-20

### Added
- Sparkline charts — tiny intraday price graphs inline with each stock in the watchlist dropdown
- Price alerts — right-click any stock to set above/below price targets, get macOS notifications when triggered
- Bell icon indicator on stocks with active price alerts
- Moon icon on stocks with closed markets in the watchlist
- Reorder stocks via Move Up/Move Down in the right-click context menu
- Currency symbols in both compact and normal menu bar display
- Foreground notification delivery — alerts show as popup banners even while app is running
- Notification permission prompt with link to System Settings when disabled

### Fixed
- Price alerts no longer trigger immediately when set at the current price
- Removing a stock from the watchlist now also removes its price alerts
- Normal (non-compact) menu bar mode now reliably shows colored prices (rendered as NSImage)
- Stock rotation skips closed-market stocks when open markets are available
- Initial display no longer shows a closed-market stock when open ones exist

### Changed
- "Updated" timestamp moved to header bar alongside "Watchlist"
- Removed duplicate "Settings" header in settings panel

## [1.0.2] - 2026-02-20

### Added
- Homebrew distribution (`brew tap TerrifiedBug/tickerbar && brew install tickerbar`)
- Sparkle auto-update framework for in-app updates
- GitHub Actions release pipeline with Homebrew cask auto-update
- Appcast.xml for Sparkle update feed

### Fixed
- CFBundleVersion aligned to semver format for correct Sparkle version comparison

## [1.0.1] - 2026-02-20

### Added
- Compact menu bar mode (stacked two-line display)
- Color-coded prices in normal menu bar mode (green/red)
- Multi-exchange market hours support (US, UK, EU, Tokyo, Hong Kong, Shanghai)
- Currency symbols for international stocks (GBP, EUR, JPY, etc.)
- Ticker autocomplete search from Yahoo Finance
- Symbol validation before adding to watchlist
- Rotation speed options up to 1 minute
- "You're on the latest version" feedback for manual update checks
- App icon
- README

### Fixed
- Invalid ticker symbols could be added to watchlist without validation

## [1.0.0] - 2026-02-20

### Added
- Initial release
- Menu bar stock ticker with Yahoo Finance data
- Watchlist management (add/remove symbols)
- Stock rotation with configurable speed
- Pin a single stock to menu bar
- Refresh interval settings
- Market hours filtering
- Launch at login option
