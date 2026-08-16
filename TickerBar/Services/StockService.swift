import AppKit
import Foundation
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
@Observable
final class StockService {
    // MARK: - Published State
    var stocks: [StockItem] = []
    var currentDisplayIndex: Int = 0
    var lastUpdated: Date?
    var errorMessage: String?
    var isLoading: Bool = false

    // MARK: - Settings (backed by UserDefaults)
    var watchlist: [String] {
        didSet { defaults.set(watchlist, forKey: "watchlist") }
    }
    var displayNames: [String: String] {
        didSet { defaults.set(displayNames, forKey: "displayNames") }
    }
    var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: "refreshInterval"); rescheduleRefreshIfRunning() }
    }
    var rotationEnabled: Bool {
        didSet { defaults.set(rotationEnabled, forKey: "rotationEnabled"); restartRotationTimer() }
    }
    var rotationSpeed: TimeInterval {
        didSet { defaults.set(rotationSpeed, forKey: "rotationSpeed"); restartRotationTimer() }
    }
    var pinnedSymbol: String {
        didSet { defaults.set(pinnedSymbol, forKey: "pinnedSymbol") }
    }
    var extendedHoursEnabled: Bool {
        didSet { defaults.set(extendedHoursEnabled, forKey: "extendedHoursEnabled") }
    }
    var showPercentChange: Bool {
        didSet { defaults.set(showPercentChange, forKey: "showPercentChange") }
    }
    var compactMenuBar: Bool {
        didSet { defaults.set(compactMenuBar, forKey: "compactMenuBar") }
    }
    var baseCurrency: String {
        didSet { defaults.set(baseCurrency, forKey: "baseCurrency") }
    }
    var menuBarFontSize: Double {
        didSet { defaults.set(menuBarFontSize, forKey: "menuBarFontSize") }
    }
    var solidPopoverBackground: Bool {
        didSet { defaults.set(solidPopoverBackground, forKey: "solidPopoverBackground") }
    }

    // MARK: - Exchange Rates (e.g. "GBP" -> 1.27 means 1 GBP = 1.27 base currency units)
    var exchangeRates: [String: Double] = [:]

    static let supportedBaseCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD", "CHF"]

    // MARK: - Portfolio Holdings
    //
    // A symbol can hold multiple lots of either kind: any number of vested RSU
    // lots (value only, no cost) and any number of purchase lots (with a cost
    // basis, e.g. buy 50 @ X then 100 @ Y). Value sums all lots; gain/loss sums
    // only cost-bearing lots.
    enum LotKind: String, Codable, Equatable {
        case rsu        // vested/awarded — value only, no cost basis
        case purchase   // bought — has a cost basis
    }

    struct Holding: Codable, Equatable, Identifiable {
        var id: UUID
        var kind: LotKind
        var shares: Double
        var costBasis: Double?   // nil for rsu; set for purchase

        init(id: UUID = UUID(), kind: LotKind, shares: Double, costBasis: Double?) {
            self.id = id
            self.kind = kind
            self.shares = shares
            self.costBasis = costBasis
        }
    }

    var holdings: [String: [Holding]] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(holdings) {
                defaults.set(data, forKey: "holdings")
            }
        }
    }

    // MARK: - Price Alerts
    var priceAlerts: [PriceAlert] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(priceAlerts) {
                defaults.set(data, forKey: "priceAlerts")
            }
        }
    }

    // MARK: - Timers
    //
    // The refresh timer is a one-shot that re-arms itself after every fetch, so
    // its cadence always reflects the market state the fetch just observed.
    // A repeating timer plus a "skip the fetch while markets are closed" gate
    // deadlocks: the gate reads `marketState`, and only a fetch can update it,
    // so the first closed session freezes the app for the rest of its life.
    private var refreshTimer: Timer?
    private var rotationTimer: Timer?
    private var isScheduling = false
    private var wakeObserver: NSObjectProtocol?
    private var inFlightFetch: Task<Bool, Never>?
    private var consecutiveFailures = 0

    /// Cadence used when no watchlist session is live. Long enough to cost
    /// nothing (96 fetches a day) but short enough that the next session — or a
    /// holiday the local-clock heuristic cannot know about — is picked up soon
    /// after Yahoo reports it.
    static let idleRefreshInterval: TimeInterval = 15 * 60

    /// Bounded fast retries, so a fetch that failed only because the network
    /// wasn't up yet (the usual case moments after wake) recovers in seconds
    /// instead of waiting out a whole cadence. Beyond the last step the normal
    /// cadence takes over, so a long Yahoo outage can't turn into a hot loop.
    nonisolated static let failureBackoff: [TimeInterval] = [5, 15, 60]

    // MARK: - Networking (all Yahoo HTTP/auth/parse lives in YahooFinanceClient)
    private let api = YahooFinanceClient()

    // MARK: - Constants
    nonisolated static let defaultWatchlist = ["AAPL", "GOOGL", "MSFT", "AMZN", "TSLA"]

    // MARK: - Persistence
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: "watchlist"), !saved.isEmpty {
            self.watchlist = saved
        } else {
            self.watchlist = Self.defaultWatchlist
        }
        self.displayNames = defaults.dictionary(forKey: "displayNames") as? [String: String] ?? [:]
        self.refreshInterval = defaults.double(forKey: "refreshInterval").nonZero ?? 60
        self.rotationEnabled = defaults.object(forKey: "rotationEnabled") as? Bool ?? true
        self.rotationSpeed = defaults.double(forKey: "rotationSpeed").nonZero ?? 5
        self.pinnedSymbol = defaults.string(forKey: "pinnedSymbol") ?? Self.defaultWatchlist[0]
        self.extendedHoursEnabled = defaults.bool(forKey: "extendedHoursEnabled")
        self.showPercentChange = defaults.object(forKey: "showPercentChange") as? Bool ?? true
        self.compactMenuBar = defaults.object(forKey: "compactMenuBar") as? Bool ?? false
        self.baseCurrency = defaults.string(forKey: "baseCurrency") ?? "USD"
        self.menuBarFontSize = defaults.double(forKey: "menuBarFontSize").nonZero ?? 10
        self.solidPopoverBackground = defaults.bool(forKey: "solidPopoverBackground")

        if let alertData = defaults.data(forKey: "priceAlerts"),
           let savedAlerts = try? JSONDecoder().decode([PriceAlert].self, from: alertData) {
            self.priceAlerts = savedAlerts
        }

        if let holdingsData = defaults.data(forKey: "holdings") {
            if let modern = try? JSONDecoder().decode([String: [Holding]].self, from: holdingsData) {
                self.holdings = modern
            } else {
                // Migrate the legacy single-record shape {shares, costBasis} into
                // a one-element purchase lot per symbol. Keep the same key so
                // existing users don't lose their holdings.
                struct LegacyHolding: Codable { var shares: Double; var costBasis: Double }
                if let legacy = try? JSONDecoder().decode([String: LegacyHolding].self, from: holdingsData) {
                    self.holdings = legacy.mapValues { [Holding(kind: .purchase, shares: $0.shares, costBasis: $0.costBasis)] }
                }
            }
        }
    }

    // MARK: - Display

    var currentDisplayStock: StockItem? {
        guard !stocks.isEmpty else { return nil }
        if rotationEnabled {
            return stocks[currentDisplayIndex % stocks.count]
        } else {
            return stocks.first { $0.symbol == pinnedSymbol } ?? stocks.first
        }
    }

    /// Move the rotation index onto an open market when one exists, so the
    /// displayed stock and `currentDisplayIndex` never disagree (the getter is
    /// side-effect free). Call this whenever the stock set changes.
    func normalizeDisplayIndex() {
        guard rotationEnabled, !stocks.isEmpty else { return }
        let bounded = currentDisplayIndex % stocks.count
        if !isDisplayActive(stocks[bounded]),
           let activeIndex = stocks.firstIndex(where: isDisplayActive) {
            currentDisplayIndex = activeIndex
        } else {
            currentDisplayIndex = bounded
        }
    }

    var menuBarText: String {
        currentDisplayStock?.menuBarText ?? "Loading..."
    }

    func advanceDisplay() {
        guard !stocks.isEmpty, rotationEnabled else { return }

        if !stocks.contains(where: isDisplayActive) {
            // All markets closed — rotate through everything
            currentDisplayIndex = (currentDisplayIndex + 1) % stocks.count
            return
        }

        // Find the next active stock after the current index.
        let startIndex = currentDisplayIndex
        for offset in 1...stocks.count {
            let candidate = (startIndex + offset) % stocks.count
            if isDisplayActive(stocks[candidate]) {
                currentDisplayIndex = candidate
                return
            }
        }
    }

    // MARK: - Market Hours

    /// Check if the exchange for a given timezone is open.
    /// Uses the stock's exchangeTimezoneName from Yahoo Finance API.
    nonisolated static func isMarketOpen(timezoneName: String? = nil, at date: Date = Date()) -> Bool {
        let tzID = timezoneName ?? "America/New_York"
        var calendar = Calendar(identifier: .gregorian)
        guard let tz = TimeZone(identifier: tzID) else { return true }
        calendar.timeZone = tz

        let weekday = calendar.component(.weekday, from: date)
        // 1 = Sunday, 7 = Saturday
        guard weekday >= 2 && weekday <= 6 else { return false }

        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let minuteOfDay = hour * 60 + minute

        // Approximate market hours for major exchanges (local time)
        // US (NYSE/NASDAQ): 9:30-16:00, UK (LSE): 8:00-16:30,
        // Europe: 9:00-17:30, Asia varies but ~9:00-15:00
        let (marketOpen, marketClose): (Int, Int) = switch tzID {
        case let tz where tz.starts(with: "Europe/London"):
            (8 * 60, 16 * 60 + 30)       // LSE: 8:00-16:30
        case let tz where tz.starts(with: "Europe/"):
            (9 * 60, 17 * 60 + 30)       // EU: 9:00-17:30
        case let tz where tz.starts(with: "Asia/Tokyo"):
            (9 * 60, 15 * 60)            // TSE: 9:00-15:00
        case let tz where tz.starts(with: "Asia/Hong_Kong"), let tz where tz.starts(with: "Asia/Shanghai"):
            (9 * 60 + 30, 16 * 60)       // HKEX/SSE: 9:30-16:00
        default:
            (9 * 60 + 30, 16 * 60)       // US default: 9:30-16:00
        }

        // Major Asian exchanges halt for a midday lunch break; treat it as closed.
        let lunch: (open: Int, close: Int)? = switch tzID {
        case let tz where tz.starts(with: "Asia/Tokyo"):
            (11 * 60 + 30, 12 * 60 + 30)         // TSE lunch 11:30–12:30
        case let tz where tz.starts(with: "Asia/Hong_Kong"), let tz where tz.starts(with: "Asia/Shanghai"):
            (12 * 60, 13 * 60)                    // HKEX/SSE lunch 12:00–13:00
        default:
            nil
        }
        if let lunch, minuteOfDay >= lunch.open && minuteOfDay < lunch.close {
            return false
        }

        return minuteOfDay >= marketOpen && minuteOfDay < marketClose
    }

    /// Whether a stock's market is currently open. Prefers Yahoo's freshly
    /// fetched `marketState` (REGULAR = open) over the local-clock heuristic,
    /// which can't know holidays or half-days; falls back to the clock when no
    /// marketState is available yet (e.g. before the first refresh).
    nonisolated static func isOpen(_ stock: StockItem, at date: Date = Date()) -> Bool {
        if let state = stock.marketState {
            return state == "REGULAR"
        }
        return isMarketOpen(timezoneName: stock.exchangeTimezoneName, at: date)
    }

    private func isDisplayActive(_ stock: StockItem) -> Bool {
        Self.isOpen(stock) || (extendedHoursEnabled && stock.hasExtendedTradingSession)
    }

    /// Regular-session status for the "Markets Closed" banner.
    var anyRegularMarketOpen: Bool {
        if stocks.isEmpty { return Self.isMarketOpen() }
        return stocks.contains { Self.isOpen($0) }
    }

    /// Returns true if any stock has a session eligible for live display.
    var anyMarketActive: Bool {
        if stocks.isEmpty { return Self.isMarketOpen() }
        return stocks.contains(where: isDisplayActive)
    }

    /// Fetches every watchlist quote, then re-arms the refresh timer for the
    /// market state that fetch observed. Concurrent callers — timer, wake,
    /// popover, manual button — coalesce onto the one in-flight fetch. Returns
    /// false when the fetch failed outright and last-good data was kept.
    @discardableResult
    func fetchAllQuotes() async -> Bool {
        if let inFlightFetch { return await inFlightFetch.value }
        let fetch = Task { @MainActor in await performFetch() }
        inFlightFetch = fetch
        let succeeded = await fetch.value
        inFlightFetch = nil

        if succeeded {
            consecutiveFailures = 0
        } else if consecutiveFailures <= Self.failureBackoff.count {
            consecutiveFailures += 1
        }
        rescheduleRefreshIfRunning()
        return succeeded
    }

    /// Refresh only when the displayed data has aged past one refresh interval.
    /// Called as the watchlist opens, so what you actually look at is current
    /// even while the slow idle cadence is running.
    func refreshIfStale() async {
        guard let lastUpdated else {
            await fetchAllQuotes()
            return
        }
        if Date().timeIntervalSince(lastUpdated) >= refreshInterval {
            await fetchAllQuotes()
        }
    }

    private func performFetch() async -> Bool {
        isLoading = true

        // Ensure we have a valid crumb before fetching
        do {
            try await api.ensureAuth()
        } catch {
            errorMessage = "Authentication failed"
            isLoading = false
            return false
        }

        let symbols = watchlist
        let enriched: [StockItem]

        // Fast path: one batched v7 quote + one batched v8 spark call instead of
        // N per-symbol chart requests. Used ONLY when it fully covers the
        // watchlist (price AND sparkline for every symbol); otherwise we fall
        // through to the resilient per-symbol path below, so a partial or
        // unexpected batch response can never regress the display.
        if !symbols.isEmpty,
           let batch = await api.fetchBatch(
               symbols: symbols,
               crumb: api.currentCrumb,
               includePrePost: extendedHoursEnabled
           ),
           batch.count == symbols.count {
            enriched = batch
        } else {
            // First attempt with the current crumb.
            var result = await api.fetchQuotes(
                symbols: symbols,
                crumb: api.currentCrumb,
                includePrePost: extendedHoursEnabled
            )

            // If every symbol failed with an auth error, the crumb/cookie has likely
            // expired. Re-authenticate and retry once — the same recovery a manual
            // refresh used to perform, now done automatically.
            if result.items.isEmpty && result.authFailures > 0 {
                api.invalidateAuth()
                do {
                    try await api.ensureAuth()
                    result = await api.fetchQuotes(
                        symbols: symbols,
                        crumb: api.currentCrumb,
                        includePrePost: extendedHoursEnabled
                    )
                } catch {
                    // Re-auth failed; fall through to keep-last-good handling below.
                }
            }

            // Genuine total failure (after the retry). Keep the last good data so the
            // menu bar doesn't blank out, surface a soft message, and invalidate auth
            // so the next cycle re-authenticates. Deliberately leave lastUpdated alone.
            if result.items.isEmpty && !symbols.isEmpty {
                errorMessage = "Couldn't refresh — showing last update"
                api.invalidateAuth()
                isLoading = false
                return false
            }

            // Fetch v7 quote data for pre/post market prices (single batch call)
            var perSymbol = result.items
            if let crumbValue = api.currentCrumb, !symbols.isEmpty {
                let v7Data = await api.fetchV7Quotes(symbols: symbols, crumb: crumbValue)
                for i in perSymbol.indices {
                    if let extra = v7Data[perSymbol[i].symbol] {
                        perSymbol[i].postMarketPrice = extra.postMarketPrice
                        perSymbol[i].postMarketChange = extra.postMarketChange
                        perSymbol[i].postMarketChangePercent = extra.postMarketChangePercent
                        perSymbol[i].preMarketPrice = extra.preMarketPrice
                        perSymbol[i].preMarketChange = extra.preMarketChange
                        perSymbol[i].preMarketChangePercent = extra.preMarketChangePercent
                        perSymbol[i].extendedMarketPrice = extra.extendedMarketPrice
                        perSymbol[i].extendedMarketChange = extra.extendedMarketChange
                        perSymbol[i].extendedMarketChangePercent = extra.extendedMarketChangePercent
                        perSymbol[i].marketState = extra.marketState
                        perSymbol[i].fiftyTwoWeekHigh = extra.fiftyTwoWeekHigh
                        perSymbol[i].fiftyTwoWeekLow = extra.fiftyTwoWeekLow
                    }
                }
            }
            enriched = perSymbol
        }

        // Fetch exchange rates for portfolio currency conversion
        if let crumbValue = api.currentCrumb, !holdings.isEmpty {
            let currencies = Set(enriched.compactMap { stock -> String? in
                guard holdings[stock.symbol] != nil else { return nil }
                return CurrencyUnit.majorUnitCode(stock.currency)
            })
            let neededRates = currencies.filter { $0 != baseCurrency }
            if !neededRates.isEmpty {
                let rateSymbols = neededRates.map { "\($0)\(baseCurrency)=X" }
                let rates = await api.fetchExchangeRates(symbols: Array(rateSymbols), crumb: crumbValue)
                for (pair, rate) in rates {
                    // Extract source currency from "GBPUSD=X" -> "GBP"
                    let source = String(pair.prefix(3))
                    exchangeRates[source] = rate
                }
                // Base currency to itself is always 1
                exchangeRates[baseCurrency] = 1.0
            } else {
                exchangeRates = [baseCurrency: 1.0]
            }
        }

        // Merge fresh quotes with the previous snapshot so a single symbol that
        // transiently failed keeps its last-good values instead of disappearing.
        // Order follows the watchlist.
        let previous = stocks
        stocks = Self.mergedStocks(watchlist: watchlist, fresh: enriched, previous: previous)
        normalizeDisplayIndex()

        errorMessage = nil
        lastUpdated = Date()
        isLoading = false
        checkPriceAlerts()
        return true
    }

    /// Merge freshly-fetched quotes with the previous snapshot, preserving
    /// watchlist order and falling back to the last-good item for any symbol
    /// missing from `fresh`. Pure function — easy to unit test.
    nonisolated static func mergedStocks(watchlist: [String], fresh: [StockItem], previous: [StockItem]) -> [StockItem] {
        watchlist.compactMap { sym in
            fresh.first { $0.symbol == sym } ?? previous.first { $0.symbol == sym }
        }
    }

    // MARK: - Watchlist Management

    func addSymbol(_ symbol: String) {
        let uppercased = symbol.uppercased().trimmingCharacters(in: .whitespaces)
        guard !uppercased.isEmpty, !watchlist.contains(uppercased) else { return }
        watchlist.append(uppercased)
    }

    func displayName(for symbol: String) -> String {
        displayNames[symbol] ?? symbol
    }

    func setDisplayName(_ name: String, for symbol: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            displayNames.removeValue(forKey: symbol)
        } else {
            displayNames[symbol] = trimmed
        }
    }

    /// Validate a ticker by attempting to fetch its quote. Returns nil on success, or an error message.
    func validateSymbol(_ symbol: String) async -> String? {
        do {
            try await api.ensureAuth()
        } catch {
            return "Unable to validate (auth failed)"
        }

        switch await api.fetchSingle(symbol) {
        case .success:
            return nil
        case .authFailure:
            return "Couldn't validate \(symbol) right now"
        case .failure:
            return "\(symbol) is not a valid ticker symbol"
        }
    }

    func removeSymbol(_ symbol: String) {
        watchlist.removeAll { $0 == symbol }
        stocks.removeAll { $0.symbol == symbol }
        priceAlerts.removeAll { $0.symbol == symbol }
        holdings.removeValue(forKey: symbol)
        displayNames.removeValue(forKey: symbol)
        normalizeDisplayIndex()
    }

    func moveSymbol(from source: Int, to destination: Int) {
        let symbol = watchlist.remove(at: source)
        watchlist.insert(symbol, at: destination)
        // Re-sort stocks to match new watchlist order
        stocks = watchlist.compactMap { sym in
            stocks.first { $0.symbol == sym }
        }
        normalizeDisplayIndex()
    }

    // MARK: - Price Alert Management

    var notificationWarning: String?

    func addAlert(symbol: String, targetPrice: Double, isAbove: Bool, kind: AlertKind = .absolutePrice, repeating: Bool = false) {
        let alert = PriceAlert(symbol: symbol, targetPrice: targetPrice, isAbove: isAbove, kind: kind, repeating: repeating)
        priceAlerts.append(alert)
        ensureNotificationPermission()
    }

    private func ensureNotificationPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            case .denied:
                notificationWarning = "Notifications are disabled. Enable in System Settings > Notifications > TickerBar."
            default:
                notificationWarning = nil
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
            NSWorkspace.shared.open(url)
        }
        notificationWarning = nil
    }

    func removeAlert(_ alert: PriceAlert) {
        priceAlerts.removeAll { $0.id == alert.id }
    }

    func alertsForSymbol(_ symbol: String) -> [PriceAlert] {
        priceAlerts.filter { $0.symbol == symbol }
    }

    func checkPriceAlerts() {
        var triggeredAlertIDs: Set<UUID> = []

        for i in priceAlerts.indices {
            guard let stock = stocks.first(where: { $0.symbol == priceAlerts[i].symbol }) else { continue }

            if !priceAlerts[i].armed {
                // Arm on first check — skips the fetch cycle where alert was created
                priceAlerts[i].armed = true
                continue
            }

            if priceAlerts[i].isTriggered(currentPrice: stock.displayPrice, changePercent: stock.changePercent) {
                sendAlertNotification(alert: priceAlerts[i], stock: stock)
                if priceAlerts[i].repeating {
                    // Disarm so it re-arms next cycle rather than firing every cycle.
                    priceAlerts[i].armed = false
                } else {
                    triggeredAlertIDs.insert(priceAlerts[i].id)
                }
            }
        }

        if !triggeredAlertIDs.isEmpty {
            priceAlerts.removeAll { triggeredAlertIDs.contains($0.id) }
        }
    }

    private func sendAlertNotification(alert: PriceAlert, stock: StockItem) {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.symbol) Price Alert"
        let currency = stock.currencySymbol
        switch alert.kind {
        case .percentChange:
            content.body = "\(alert.symbol) is \(String(format: "%+.1f%%", stock.changePercent)) today, \(alert.directionLabel) your \(String(format: "%.1f%%", alert.targetPrice)) target"
        case .absolutePrice:
            content.body = "\(alert.symbol) is now \(currency)\(String(format: "%.2f", stock.displayPrice)), \(alert.directionLabel) your target of \(currency)\(String(format: "%.2f", alert.targetPrice))"
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Portfolio Management

    func lots(for symbol: String) -> [Holding] { holdings[symbol] ?? [] }

    func addLot(symbol: String, kind: LotKind, shares: Double, costBasis: Double?) {
        guard shares > 0 else { return }
        let cost = kind == .rsu ? nil : costBasis
        holdings[symbol, default: []].append(Holding(kind: kind, shares: shares, costBasis: cost))
    }

    func updateLot(symbol: String, id: UUID, shares: Double, costBasis: Double?) {
        guard var list = holdings[symbol], let idx = list.firstIndex(where: { $0.id == id }) else { return }
        if shares > 0 {
            list[idx].shares = shares
            list[idx].costBasis = list[idx].kind == .rsu ? nil : costBasis
            holdings[symbol] = list
        } else {
            removeLot(symbol: symbol, id: id)
        }
    }

    func removeLot(symbol: String, id: UUID) {
        guard var list = holdings[symbol] else { return }
        list.removeAll { $0.id == id }
        if list.isEmpty { holdings.removeValue(forKey: symbol) } else { holdings[symbol] = list }
    }

    // MARK: - Backup (export / import)

    /// Portable snapshot of all user data. All UserDefaults-backed state is here
    /// so a backup can move a setup to a new Mac or recover after a reset.
    struct PortfolioBackup: Codable {
        var schemaVersion: Int
        var watchlist: [String]
        var displayNames: [String: String]?
        var holdings: [String: [Holding]]
        var priceAlerts: [PriceAlert]
        var baseCurrency: String
    }

    static let backupSchemaVersion = 2

    func exportBackupData() throws -> Data {
        let backup = PortfolioBackup(
            schemaVersion: Self.backupSchemaVersion,
            watchlist: watchlist,
            displayNames: displayNames,
            holdings: holdings,
            priceAlerts: priceAlerts,
            baseCurrency: baseCurrency
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    /// Replace current data with a decoded backup. Returns false (and changes
    /// nothing) on malformed or empty input. Does not fetch — the caller should
    /// refresh afterward.
    @discardableResult
    func importBackupData(_ data: Data) -> Bool {
        guard let backup = try? JSONDecoder().decode(PortfolioBackup.self, from: data),
              !backup.watchlist.isEmpty else { return false }
        watchlist = backup.watchlist
        displayNames = (backup.displayNames ?? [:]).filter { backup.watchlist.contains($0.key) }
        holdings = backup.holdings
        priceAlerts = backup.priceAlerts
        if Self.supportedBaseCurrencies.contains(backup.baseCurrency) {
            baseCurrency = backup.baseCurrency
        }
        return true
    }

    // Portfolio totals delegate to the pure PortfolioCalculator (testable
    // without the service); this type just supplies its current state.

    var totalPortfolioValue: Double {
        PortfolioCalculator.totalValue(stocks: stocks, holdings: holdings, baseCurrency: baseCurrency, rates: exchangeRates)
    }

    var portfolioPositions: [PortfolioCalculator.Position] {
        PortfolioCalculator.positions(stocks: stocks, holdings: holdings, baseCurrency: baseCurrency, rates: exchangeRates)
    }

    var totalPortfolioCost: Double {
        PortfolioCalculator.totalCost(stocks: stocks, holdings: holdings, baseCurrency: baseCurrency, rates: exchangeRates)
    }

    var totalPortfolioGain: Double {
        PortfolioCalculator.gain(stocks: stocks, holdings: holdings, baseCurrency: baseCurrency, rates: exchangeRates)
    }

    var totalPortfolioGainPercent: Double {
        let cost = totalPortfolioCost
        return cost > 0 ? (totalPortfolioGain / cost) * 100 : 0
    }

    /// True when at least one lot has a cost basis, so gain/loss is meaningful.
    var hasCostBasis: Bool {
        PortfolioCalculator.hasCostBasis(holdings: holdings)
    }

    /// True when a held symbol's currency has no known FX rate to the base
    /// currency yet, so portfolio totals currently exclude that symbol's lots.
    var hasUnconvertedHoldings: Bool {
        PortfolioCalculator.hasUnconverted(stocks: stocks, holdings: holdings, baseCurrency: baseCurrency, rates: exchangeRates)
    }

    var baseCurrencySymbol: String {
        switch baseCurrency {
        case "GBP": return "£"
        case "EUR": return "€"
        case "JPY": return "¥"
        case "CAD": return "C$"
        case "AUD": return "A$"
        case "CHF": return "CHF "
        default: return "$"
        }
    }

    // MARK: - Symbol Search

    struct SymbolSearchResult: Identifiable {
        let id = UUID()
        let symbol: String
        let name: String
        let exchange: String
    }

    func searchSymbols(_ query: String) async -> [SymbolSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return await api.searchRaw(trimmed).map {
            SymbolSearchResult(symbol: $0.symbol, name: $0.name, exchange: $0.exchange)
        }
    }

    // MARK: - Timer Management

    func startTimers() {
        isScheduling = true
        observeWake()
        restartRotationTimer()

        // The initial fetch arms the refresh timer for whatever it observes.
        Task { @MainActor in
            await fetchAllQuotes()
        }
    }

    func stopTimers() {
        isScheduling = false
        refreshTimer?.invalidate()
        rotationTimer?.invalidate()
        refreshTimer = nil
        rotationTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Waking leaves the quotes stale by however long the lid was shut, and the
    /// pending one-shot is overdue rather than aligned to the new wall clock.
    /// Fetch straight away and let that fetch re-anchor the cadence.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchAllQuotes()
            }
        }
    }

    /// The cadence the market state observed by the last fetch calls for. A
    /// closed market only slows refreshes down; it never stops them, so
    /// `marketState` is always re-read and a reopening is always noticed. The
    /// user's interval always wins when it is slower than the idle cadence.
    var refreshCadence: TimeInterval {
        anyMarketActive ? refreshInterval : max(refreshInterval, Self.idleRefreshInterval)
    }

    /// How long until the next refresh. Failures pull the next attempt in to a
    /// bounded retry — never past the cadence, since retrying slower than the
    /// normal rhythm helps nobody — and once the retries are spent the cadence
    /// takes back over, so an outage can't become a hot loop.
    nonisolated static func refreshDelay(cadence: TimeInterval, consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0, consecutiveFailures <= failureBackoff.count else { return cadence }
        return min(failureBackoff[consecutiveFailures - 1], cadence)
    }

    var nextRefreshDelay: TimeInterval {
        Self.refreshDelay(cadence: refreshCadence, consecutiveFailures: consecutiveFailures)
    }

    private func rescheduleRefreshIfRunning() {
        guard isScheduling else { return }
        refreshTimer?.invalidate()

        let delay = nextRefreshDelay
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchAllQuotes()
            }
        }
        // Correctness comes from re-arming after each fetch, not from firing on
        // an exact second, so let the OS coalesce this wakeup with others.
        timer.tolerance = min(delay * 0.1, 30)
        // `.common` so a refresh still lands while the watchlist popover is up:
        // its menu-tracking run loop doesn't service `.default`-only timers.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func restartRotationTimer() {
        rotationTimer?.invalidate()
        guard rotationEnabled else { return }

        let timer = Timer(timeInterval: rotationSpeed, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceDisplay()
            }
        }
        timer.tolerance = min(rotationSpeed * 0.1, 1)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? {
        self == 0 ? nil : self
    }
}

// MARK: - YahooFinanceClient
//
// All Yahoo Finance HTTP, cookie+crumb auth, URL building, and JSON parsing.
// Extracted from StockService so the networking is a focused, separately
// reasoned-about unit; StockService is now a thin @Observable coordinator that
// owns app state and delegates fetching here.
@MainActor
final class YahooFinanceClient {
    private var crumb: String?
    var currentCrumb: String? { crumb }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        ]
        return URLSession(configuration: config)
    }()

    nonisolated private static let baseURL = "https://query2.finance.yahoo.com"

    enum YahooError: Error {
        case parseError
        case authError
    }

    // MARK: - Cookie + Crumb Authentication
    //
    // Yahoo Finance requires a session cookie + crumb token for API access.
    //   1. GET https://fc.yahoo.com -> sets Yahoo session cookie (404s, cookie set)
    //   2. GET .../v1/test/getcrumb -> returns plaintext crumb
    //   3. Append &crumb={crumb} to all API requests

    func ensureAuth() async throws {
        if crumb != nil { return }

        let cookieURL = URL(string: "https://fc.yahoo.com")!
        let _ = try? await Self.session.data(from: cookieURL)

        let crumbURL = URL(string: "\(Self.baseURL)/v1/test/getcrumb")!
        let (crumbData, crumbResponse) = try await Self.session.data(from: crumbURL)

        guard let httpResponse = crumbResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw YahooError.authError
        }

        guard let crumbString = String(data: crumbData, encoding: .utf8),
              !crumbString.isEmpty,
              !crumbString.contains("<html>") else {
            throw YahooError.authError
        }

        self.crumb = crumbString
    }

    /// Invalidate auth so the next request re-fetches cookie + crumb.
    func invalidateAuth() {
        crumb = nil
    }

    // MARK: - URL Building
    //
    // Yahoo crumbs commonly contain '+', '/', and '='. A raw interpolated URL,
    // or `.urlQueryAllowed` over a whole URL string, leaves '+' intact — and a
    // server decodes a query '+' as a space, corrupting the crumb. Build every
    // request with explicit per-component encoding so '+', '&', '#', '=' in a
    // value are escaped, and symbols like "^GSPC" resolve in the path.

    nonisolated static func encodedQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private nonisolated static func yahooURL(path: String, query: [(name: String, value: String)]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query2.finance.yahoo.com"
        components.path = path
        components.percentEncodedQuery = query
            .map { "\($0.name)=\(encodedQueryValue($0.value))" }
            .joined(separator: "&")
        return components.url
    }

    nonisolated static func chartURL(symbol: String, crumb: String, includePrePost: Bool = false) -> URL? {
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.remove(charactersIn: "/")
        let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? symbol
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query2.finance.yahoo.com"
        components.percentEncodedPath = "/v8/finance/chart/\(encodedSymbol)"
        components.percentEncodedQuery = "interval=5m&range=1d&includePrePost=\(includePrePost)&crumb=\(encodedQueryValue(crumb))"
        return components.url
    }

    nonisolated static func quoteURL(symbols: [String], crumb: String) -> URL? {
        yahooURL(path: "/v7/finance/quote", query: [
            ("symbols", symbols.joined(separator: ",")),
            ("formatted", "false"),
            ("crumb", crumb),
        ])
    }

    nonisolated static func searchURL(query: String) -> URL? {
        yahooURL(path: "/v1/finance/search", query: [
            ("q", query),
            ("quotesCount", "6"),
            ("newsCount", "0"),
            ("listsCount", "0"),
        ])
    }

    // MARK: - Quote fetching

    enum FetchOutcome: Sendable {
        case success(StockItem)
        case authFailure
        case failure
    }

    /// Fetch all symbols concurrently. Returns successfully-parsed items plus a
    /// count of auth failures (HTTP 401/403) so the caller can decide whether to
    /// re-authenticate and retry.
    func fetchQuotes(
        symbols: [String],
        crumb: String?,
        includePrePost: Bool = false
    ) async -> (items: [StockItem], authFailures: Int) {
        await withTaskGroup(of: FetchOutcome.self) { group in
            for symbol in symbols {
                group.addTask {
                    await Self.fetchQuote(for: symbol, crumb: crumb, includePrePost: includePrePost)
                }
            }
            var items: [StockItem] = []
            var authFailures = 0
            for await outcome in group {
                switch outcome {
                case .success(let stock): items.append(stock)
                case .authFailure: authFailures += 1
                case .failure: break
                }
            }
            return (items: items, authFailures: authFailures)
        }
    }

    /// Fetch a single symbol's quote (used for ticker validation).
    func fetchSingle(_ symbol: String) async -> FetchOutcome {
        await Self.fetchQuote(for: symbol, crumb: crumb)
    }

    nonisolated static func fetchQuote(
        for symbol: String,
        crumb: String?,
        includePrePost: Bool = false
    ) async -> FetchOutcome {
        guard let crumb else { return .failure }
        guard let url = chartURL(symbol: symbol, crumb: crumb, includePrePost: includePrePost) else { return .failure }

        do {
            let (data, response) = try await session.data(from: url)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .authFailure
            }

            return .success(try parseQuoteResponse(data: data))
        } catch {
            return .failure
        }
    }

    nonisolated static func parseQuoteResponse(data: Data) throws -> StockItem {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let chart = json?["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let result = results.first,
              let meta = result["meta"] as? [String: Any],
              let symbol = meta["symbol"] as? String,
              let price = meta["regularMarketPrice"] as? Double,
              let previousClose = meta["chartPreviousClose"] as? Double
        else {
            throw YahooError.parseError
        }

        let name = meta["longName"] as? String
            ?? meta["shortName"] as? String
            ?? symbol
        let exchangeTZ = meta["exchangeTimezoneName"] as? String
        let currency = meta["currency"] as? String

        var intradayPrices: [Double] = []
        if let indicators = result["indicators"] as? [String: Any],
           let quotes = indicators["quote"] as? [[String: Any]],
           let quote = quotes.first,
           let closes = quote["close"] as? [Any] {
            intradayPrices = closes.compactMap { $0 as? Double }
        }

        let dayHigh = meta["regularMarketDayHigh"] as? Double
        let dayLow = meta["regularMarketDayLow"] as? Double

        return StockItem(symbol: symbol, name: name, price: price, previousClose: previousClose, exchangeTimezoneName: exchangeTZ, currency: currency, intradayPrices: intradayPrices, dayHigh: dayHigh, dayLow: dayLow)
    }

    // MARK: - V7 Quote (pre/post market, market state)

    struct V7QuoteData {
        var postMarketPrice: Double?
        var postMarketChange: Double?
        var postMarketChangePercent: Double?
        var preMarketPrice: Double?
        var preMarketChange: Double?
        var preMarketChangePercent: Double?
        var extendedMarketPrice: Double?
        var extendedMarketChange: Double?
        var extendedMarketChangePercent: Double?
        var marketState: String?
        var fiftyTwoWeekHigh: Double?
        var fiftyTwoWeekLow: Double?
    }

    /// Batch fetch v7 quote data for all symbols (single HTTP call).
    func fetchV7Quotes(symbols: [String], crumb: String) async -> [String: V7QuoteData] {
        guard let url = Self.quoteURL(symbols: symbols, crumb: crumb) else { return [:] }

        do {
            let (data, response) = try await Self.session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [:] }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let quoteResponse = json?["quoteResponse"] as? [String: Any],
                  let results = quoteResponse["result"] as? [[String: Any]] else { return [:] }

            var dict: [String: V7QuoteData] = [:]
            for quote in results {
                guard let symbol = quote["symbol"] as? String else { continue }
                dict[symbol] = V7QuoteData(
                    postMarketPrice: quote["postMarketPrice"] as? Double,
                    postMarketChange: quote["postMarketChange"] as? Double,
                    postMarketChangePercent: quote["postMarketChangePercent"] as? Double,
                    preMarketPrice: quote["preMarketPrice"] as? Double,
                    preMarketChange: quote["preMarketChange"] as? Double,
                    preMarketChangePercent: quote["preMarketChangePercent"] as? Double,
                    extendedMarketPrice: quote["extendedMarketPrice"] as? Double,
                    extendedMarketChange: quote["extendedMarketChange"] as? Double,
                    extendedMarketChangePercent: quote["extendedMarketChangePercent"] as? Double,
                    marketState: quote["marketState"] as? String,
                    fiftyTwoWeekHigh: quote["fiftyTwoWeekHigh"] as? Double,
                    fiftyTwoWeekLow: quote["fiftyTwoWeekLow"] as? Double
                )
            }
            return dict
        } catch {
            return [:]
        }
    }

    // MARK: - Exchange Rates

    /// Fetch exchange rates via v7/quote (e.g. symbols = ["GBPUSD=X", "EURUSD=X"]).
    func fetchExchangeRates(symbols: [String], crumb: String) async -> [String: Double] {
        guard let url = Self.quoteURL(symbols: symbols, crumb: crumb) else { return [:] }

        do {
            let (data, response) = try await Self.session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [:] }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let quoteResponse = json?["quoteResponse"] as? [String: Any],
                  let results = quoteResponse["result"] as? [[String: Any]] else { return [:] }

            var rates: [String: Double] = [:]
            for quote in results {
                guard let symbol = quote["symbol"] as? String,
                      let price = quote["regularMarketPrice"] as? Double else { continue }
                let source = String(symbol.prefix(3))
                rates[source] = price
            }
            return rates
        } catch {
            return [:]
        }
    }

    // MARK: - Batch fetching (v7 quote + v8 spark)

    nonisolated static func sparkURL(
        symbols: [String],
        crumb: String,
        includePrePost: Bool = false
    ) -> URL? {
        yahooURL(path: "/v8/finance/spark", query: [
            ("symbols", symbols.joined(separator: ",")),
            ("range", "1d"),
            ("interval", "5m"),
            ("includePrePost", includePrePost ? "true" : "false"),
            ("crumb", crumb),
        ])
    }

    /// Two batched calls (v7 quote + v8 spark) covering the whole watchlist,
    /// instead of one chart request per symbol. Returns fully-populated items
    /// ONLY when both calls cover every symbol with a usable sparkline;
    /// otherwise nil, so the caller falls back to the per-symbol path and the
    /// display is never degraded by a partial/unexpected batch response.
    func fetchBatch(
        symbols: [String],
        crumb: String?,
        includePrePost: Bool = false
    ) async -> [StockItem]? {
        guard let crumb, !symbols.isEmpty,
              let v7url = Self.quoteURL(symbols: symbols, crumb: crumb),
              let sparkurl = Self.sparkURL(
                  symbols: symbols,
                  crumb: crumb,
                  includePrePost: includePrePost
              ) else { return nil }

        async let v7Resp = Self.session.data(from: v7url)
        async let sparkResp = Self.session.data(from: sparkurl)
        do {
            let (v7data, v7r) = try await v7Resp
            let (sparkdata, sparkr) = try await sparkResp
            guard (v7r as? HTTPURLResponse)?.statusCode == 200,
                  (sparkr as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            let quotes = Self.parseV7Full(data: v7data)
            let sparks = Self.parseSpark(data: sparkdata)

            var items: [StockItem] = []
            for sym in symbols {
                guard var item = quotes[sym],
                      let series = sparks[sym], series.count >= 2 else { return nil }
                item.intradayPrices = series
                items.append(item)
            }
            return items
        } catch {
            return nil
        }
    }

    /// Parse a v7 quote response into fully-populated StockItems (price,
    /// previous close, name, timezone, currency, day range, pre/post market,
    /// 52-week range, market state).
    nonisolated static func parseV7Full(data: Data) -> [String: StockItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quoteResponse = json["quoteResponse"] as? [String: Any],
              let results = quoteResponse["result"] as? [[String: Any]] else { return [:] }

        var dict: [String: StockItem] = [:]
        for q in results {
            guard let symbol = q["symbol"] as? String,
                  let price = q["regularMarketPrice"] as? Double,
                  let prevClose = q["regularMarketPreviousClose"] as? Double else { continue }
            let name = (q["longName"] as? String) ?? (q["shortName"] as? String)
                ?? (q["displayName"] as? String) ?? symbol
            var item = StockItem(
                symbol: symbol, name: name, price: price, previousClose: prevClose,
                exchangeTimezoneName: q["exchangeTimezoneName"] as? String,
                currency: q["currency"] as? String,
                intradayPrices: [],
                dayHigh: q["regularMarketDayHigh"] as? Double,
                dayLow: q["regularMarketDayLow"] as? Double
            )
            item.postMarketPrice = q["postMarketPrice"] as? Double
            item.postMarketChange = q["postMarketChange"] as? Double
            item.postMarketChangePercent = q["postMarketChangePercent"] as? Double
            item.preMarketPrice = q["preMarketPrice"] as? Double
            item.preMarketChange = q["preMarketChange"] as? Double
            item.preMarketChangePercent = q["preMarketChangePercent"] as? Double
            item.extendedMarketPrice = q["extendedMarketPrice"] as? Double
            item.extendedMarketChange = q["extendedMarketChange"] as? Double
            item.extendedMarketChangePercent = q["extendedMarketChangePercent"] as? Double
            item.marketState = q["marketState"] as? String
            item.fiftyTwoWeekHigh = q["fiftyTwoWeekHigh"] as? Double
            item.fiftyTwoWeekLow = q["fiftyTwoWeekLow"] as? Double
            dict[symbol] = item
        }
        return dict
    }

    /// Parse a v8 spark response into intraday close series per symbol.
    nonisolated static func parseSpark(data: Data) -> [String: [Double]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spark = json["spark"] as? [String: Any],
              let results = spark["result"] as? [[String: Any]] else { return [:] }

        var dict: [String: [Double]] = [:]
        for r in results {
            guard let symbol = r["symbol"] as? String,
                  let responses = r["response"] as? [[String: Any]],
                  let first = responses.first,
                  let indicators = first["indicators"] as? [String: Any],
                  let quotes = indicators["quote"] as? [[String: Any]],
                  let quote = quotes.first,
                  let closes = quote["close"] as? [Any] else { continue }
            dict[symbol] = closes.compactMap { $0 as? Double }
        }
        return dict
    }

    // MARK: - Symbol Search

    /// Search for symbols; returns raw tuples the caller maps to its own type.
    func searchRaw(_ query: String) async -> [(symbol: String, name: String, exchange: String)] {
        guard let url = Self.searchURL(query: query) else { return [] }

        do {
            let (data, response) = try await Self.session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let quotes = json?["quotes"] as? [[String: Any]] else { return [] }

            return quotes.compactMap { quote in
                guard let symbol = quote["symbol"] as? String,
                      let name = (quote["shortname"] as? String) ?? (quote["longname"] as? String) else { return nil }
                let exchange = quote["exchDisp"] as? String ?? ""
                return (symbol: symbol, name: name, exchange: exchange)
            }
        } catch {
            return []
        }
    }
}
