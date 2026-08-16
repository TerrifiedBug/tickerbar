import SwiftUI
import AppKit

struct WatchlistView: View {
    @Bindable var service: StockService
    @ObservedObject var updateChecker: UpdateChecker
    @State private var newSymbol = ""
    @State private var showSettings = false
    @State private var addError: String?
    @State private var isValidating = false
    @State private var searchResults: [StockService.SymbolSearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var displayNameSymbol: String?
    @State private var displayNameText = ""
    @State private var alertSymbol: String?
    @State private var alertPriceText = ""
    @State private var alertIsAbove = true
    @State private var alertKind: AlertKind = .absolutePrice
    @State private var alertRepeating = false
    @State private var holdingsSymbol: String?
    @State private var holdingsKind: StockService.LotKind = .purchase
    @State private var editingLotID: UUID?
    @State private var holdingsSharesText = ""
    @State private var holdingsCostText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Watchlist")
                    .font(.headline)
                if let lastUpdated = service.lastUpdated {
                    Text(lastUpdated.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if service.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: {
                    Task { await service.fetchAllQuotes() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Market status
            if !service.anyRegularMarketOpen {
                HStack {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(.secondary)
                    Text("Markets Closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            // Error
            if let error = service.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            PortfolioSummaryView(service: service)

            // Surface holdings excluded from the total because their exchange
            // rate hasn't loaded yet, rather than silently mis-valuing them.
            if service.hasUnconvertedHoldings {
                Text("Some holdings excluded — exchange rates updating…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
            }

            Divider()

            // Stock list
            if service.stocks.isEmpty && !service.isLoading {
                Text("No data yet")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(Array(service.stocks.enumerated()), id: \.element.id) { index, stock in
                    StockRowView(
                        stock: stock,
                        displayName: service.displayName(for: stock.symbol),
                        includeExtendedHours: service.extendedHoursEnabled,
                        hasAlert: !service.alertsForSymbol(stock.symbol).isEmpty,
                        lots: service.lots(for: stock.symbol)
                    )
                        .onTapGesture {
                            openYahooFinance(symbol: stock.symbol)
                        }
                        .contextMenu {
                            if index > 0 {
                                Button("Move Up") {
                                    withAnimation { service.moveSymbol(from: index, to: index - 1) }
                                }
                            }
                            if index < service.stocks.count - 1 {
                                Button("Move Down") {
                                    withAnimation { service.moveSymbol(from: index, to: index + 1) }
                                }
                            }

                            Divider()
                            Button(service.displayNames[stock.symbol] == nil ? "Set Display Name..." : "Edit Display Name...") {
                                displayNameSymbol = stock.symbol
                                displayNameText = service.displayNames[stock.symbol] ?? ""
                            }

                            Divider()

                            Button("Set Price Alert...") {
                                alertPriceText = String(format: "%.2f", stock.displayPrice)
                                alertIsAbove = true
                                alertKind = .absolutePrice
                                alertRepeating = false
                                alertSymbol = stock.symbol
                            }

                            let alerts = service.alertsForSymbol(stock.symbol)
                            if !alerts.isEmpty {
                                Divider()
                                ForEach(alerts) { alert in
                                    Button("Remove: \(alert.directionLabel) \(alertTargetLabel(alert, currencySymbol: stock.currencySymbol))\(alert.repeating ? " (repeat)" : "")") {
                                        service.removeAlert(alert)
                                    }
                                }
                            }

                            Divider()

                            Button("Add RSUs...") {
                                holdingsKind = .rsu
                                editingLotID = nil
                                holdingsSharesText = ""
                                holdingsCostText = ""
                                holdingsSymbol = stock.symbol
                            }
                            Button("Add Purchase...") {
                                holdingsKind = .purchase
                                editingLotID = nil
                                holdingsSharesText = ""
                                holdingsCostText = ""
                                holdingsSymbol = stock.symbol
                            }
                            let lots = service.lots(for: stock.symbol)
                            if !lots.isEmpty {
                                Divider()
                                ForEach(lots) { lot in
                                    Menu(lotMenuLabel(lot, currencySymbol: stock.currencySymbol)) {
                                        Button("Edit...") {
                                            holdingsKind = lot.kind
                                            editingLotID = lot.id
                                            holdingsSharesText = String(format: "%.2f", lot.shares)
                                            holdingsCostText = lot.costBasis.map { String(format: "%.2f", $0) } ?? ""
                                            holdingsSymbol = stock.symbol
                                        }
                                        Button("Remove") { service.removeLot(symbol: stock.symbol, id: lot.id) }
                                    }
                                }
                            }

                            Divider()
                            Button("Remove \(stock.symbol)") {
                                service.removeSymbol(stock.symbol)
                            }
                        }
                }
            }

            // Display name input
            if let symbol = displayNameSymbol {
                VStack(spacing: 8) {
                    HStack {
                        Text("Display name for \(symbol)")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { displayNameSymbol = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Replaces the ticker and hides its currency symbol in the menu bar and watchlist.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        TextField("Alias", text: $displayNameText)
                            .textFieldStyle(.roundedBorder)
                        if service.displayNames[symbol] != nil {
                            Button("Clear", role: .destructive) {
                                service.setDisplayName("", for: symbol)
                                displayNameSymbol = nil
                            }
                        }
                        Button("Save") {
                            service.setDisplayName(displayNameText, for: symbol)
                            displayNameSymbol = nil
                        }
                        .disabled(displayNameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background.opacity(0.5))
            }

            // Price alert input
            if let symbol = alertSymbol {
                VStack(spacing: 8) {
                    HStack {
                        Text("Alert for \(symbol)")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { alertSymbol = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 6) {
                        Picker("", selection: $alertKind) {
                            Text("Price").tag(AlertKind.absolutePrice)
                            Text("% Chg").tag(AlertKind.percentChange)
                        }
                        .labelsHidden()
                        .frame(width: 84)
                        Picker("", selection: $alertIsAbove) {
                            Text("Above").tag(true)
                            Text("Below").tag(false)
                        }
                        .labelsHidden()
                        .frame(width: 70)
                        TextField(alertKind == .percentChange ? "%" : "Price", text: $alertPriceText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                    HStack(spacing: 8) {
                        Toggle("Repeat", isOn: $alertRepeating)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        Spacer()
                        Button("Set") {
                            if let value = Double(alertPriceText) {
                                service.addAlert(symbol: symbol, targetPrice: value, isAbove: alertIsAbove, kind: alertKind, repeating: alertRepeating)
                                alertSymbol = nil
                            }
                        }
                        .disabled(Double(alertPriceText) == nil)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background.opacity(0.5))
            }

            // Holdings input (RSU lot = shares only; Purchase lot = shares + cost)
            if let symbol = holdingsSymbol {
                VStack(spacing: 8) {
                    HStack {
                        Text(holdingsFormTitle(symbol: symbol))
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { holdingsSymbol = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shares")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField("0", text: $holdingsSharesText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                        if holdingsKind == .purchase {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Avg Cost")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("0.00", text: $holdingsCostText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                            }
                        }
                        Spacer()
                        VStack(spacing: 2) {
                            Text(" ")
                                .font(.caption2)
                            Button("Save") {
                                saveHoldingLot(symbol: symbol)
                            }
                            .disabled(!canSaveHoldingLot)
                        }
                    }
                    if holdingsKind == .rsu {
                        Text("Vested shares — value only, no cost basis.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background.opacity(0.5))
            }

            // Notification warning
            if let warning = service.notificationWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") {
                        service.openNotificationSettings()
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.yellow.opacity(0.1))
            }

            Divider()

            // Add stock
            HStack {
                TextField("Add symbol...", text: $newSymbol)
                    .textFieldStyle(.plain)
                    .onSubmit { addSymbol() }
                    .onChange(of: newSymbol) { _, newValue in
                        searchTask?.cancel()
                        let query = newValue.trimmingCharacters(in: .whitespaces)
                        if query.isEmpty {
                            searchResults = []
                            return
                        }
                        searchTask = Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            let results = await service.searchSymbols(query)
                            if !Task.isCancelled {
                                searchResults = results
                            }
                        }
                    }
                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: addSymbol) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(newSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search results dropdown
            if !searchResults.isEmpty && !newSymbol.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(spacing: 0) {
                    ForEach(searchResults) { result in
                        Button(action: {
                            selectSearchResult(result)
                        }) {
                            HStack {
                                Text(result.symbol)
                                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                                Text(result.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(result.exchange)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.background.opacity(0.5))
            }

            if let addError {
                Text(addError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()

            // Bottom bar
            HStack {
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Inline settings
            if showSettings {
                Divider()
                SettingsView(service: service, updateChecker: updateChecker)
            }
        }
        .frame(width: 300)
        // Opening the watchlist is a direct request to look at the numbers, so
        // top them up if the idle cadence has let them age past one interval.
        .task { await service.refreshIfStale() }
        .background(service.solidPopoverBackground ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .background(
            // Measure the content's settled height in SwiftUI space and feed it
            // to the panel resizer. GeometryReader reports the laid-out size on
            // every layout pass (grow *and* shrink), so the panel follows the
            // content down when Settings collapses.
            GeometryReader { proxy in
                MenuBarWindowResizer(targetHeight: proxy.size.height)
            }
        )
    }

    // MARK: - Alert + holdings helpers

    private func alertTargetLabel(_ alert: PriceAlert, currencySymbol: String) -> String {
        alert.kind == .percentChange
            ? String(format: "%.1f%%", alert.targetPrice)
            : "\(currencySymbol)\(String(format: "%.2f", alert.targetPrice))"
    }

    private func lotMenuLabel(_ lot: StockService.Holding, currencySymbol: String) -> String {
        if lot.kind == .rsu {
            return "RSU \(String(format: "%.2f", lot.shares)) sh"
        }
        let cost = lot.costBasis ?? 0
        return "Buy \(String(format: "%.2f", lot.shares)) sh @ \(currencySymbol)\(String(format: "%.2f", cost))"
    }

    private func holdingsFormTitle(symbol: String) -> String {
        let action = editingLotID != nil ? "Edit" : (holdingsKind == .rsu ? "Add RSUs" : "Add Purchase")
        return "\(action) for \(symbol)"
    }

    private var canSaveHoldingLot: Bool {
        guard Double(holdingsSharesText) != nil else { return false }
        if holdingsKind == .purchase {
            return Double(holdingsCostText.trimmingCharacters(in: .whitespaces)) != nil
        }
        return true
    }

    private func saveHoldingLot(symbol: String) {
        guard let shares = Double(holdingsSharesText) else { return }
        let cost = holdingsKind == .rsu ? nil : Double(holdingsCostText.trimmingCharacters(in: .whitespaces))
        if let id = editingLotID {
            service.updateLot(symbol: symbol, id: id, shares: shares, costBasis: cost)
        } else {
            service.addLot(symbol: symbol, kind: holdingsKind, shares: shares, costBasis: cost)
        }
        holdingsSymbol = nil
    }

    private func addSymbol() {
        let symbol = newSymbol.uppercased().trimmingCharacters(in: .whitespaces)
        guard !symbol.isEmpty else { return }

        if service.watchlist.contains(symbol) {
            addError = "\(symbol) is already in your watchlist"
            newSymbol = ""
            return
        }

        addError = nil
        isValidating = true
        let symbolToAdd = symbol
        newSymbol = ""

        Task {
            if let error = await service.validateSymbol(symbolToAdd) {
                addError = error
            } else {
                service.addSymbol(symbolToAdd)
                await service.fetchAllQuotes()
            }
            isValidating = false
        }
    }

    private func selectSearchResult(_ result: StockService.SymbolSearchResult) {
        let symbol = result.symbol
        searchResults = []
        newSymbol = ""

        if service.watchlist.contains(symbol) {
            addError = "\(symbol) is already in your watchlist"
            return
        }

        addError = nil
        service.addSymbol(symbol)
        Task { await service.fetchAllQuotes() }
    }

    private func openYahooFinance(symbol: String) {
        guard let url = URL(string: "https://finance.yahoo.com/quote/\(symbol)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PortfolioSummaryView: View {
    @Bindable var service: StockService
    @State private var expanded = false

    var body: some View {
        let positions = service.portfolioPositions
        if !positions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { expanded.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.pie.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Portfolio")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            Text(money(service.totalPortfolioValue))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                            if service.hasCostBasis {
                                Text(signedPercent(service.totalPortfolioGainPercent))
                                    .font(.caption2)
                                    .foregroundStyle(service.totalPortfolioGain >= 0 ? .green : .red)
                            }
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, height: 24)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide portfolio positions" : "Show portfolio positions")

                if expanded {
                    positionList(positions)
                        .padding(.leading, 36)
                        .padding(.trailing, 12)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func positionList(_ positions: [PortfolioCalculator.Position]) -> some View {
        if positions.count > 4 {
            ScrollView {
                positionRows(positions)
            }
            .frame(height: 148)
        } else {
            positionRows(positions)
        }
    }

    private func positionRows(_ positions: [PortfolioCalculator.Position]) -> some View {
        VStack(spacing: 4) {
            ForEach(positions) { position in
                positionRow(position)
            }
        }
    }

    private func positionRow(_ position: PortfolioCalculator.Position) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(service.displayName(for: position.stock.symbol))
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(shares(position.shares)) sh")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                if let value = position.value {
                    Text(money(value))
                        .font(.caption)
                        .monospacedDigit()
                } else {
                    Text("FX updating…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let gainPercent = position.gainPercent {
                    Text(signedPercent(gainPercent))
                        .font(.caption2)
                        .foregroundStyle(gainPercent >= 0 ? .green : .red)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func money(_ value: Double) -> String {
        let amount = value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(0))
        )
        return "\(service.baseCurrencySymbol)\(amount)"
    }

    private func shares(_ value: Double) -> String {
        value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(0...4))
        )
    }

    private func signedPercent(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "−")\(String(format: "%.1f%%", abs(value)))"
    }
}

struct StockRowView: View {
    let stock: StockItem
    let displayName: String
    let includeExtendedHours: Bool
    var hasAlert: Bool = false
    var lots: [StockService.Holding] = []
    @State private var expanded = false

    private var tooltipText: String {
        var lines: [String] = []
        let cs = stock.currencySymbol

        if let high = stock.displayDayHigh, let low = stock.displayDayLow {
            lines.append("Day: \(cs)\(String(format: "%.2f", low)) - \(cs)\(String(format: "%.2f", high))")
        }
        if let h52 = stock.display52WeekHigh, let l52 = stock.display52WeekLow {
            lines.append("52w: \(cs)\(String(format: "%.2f", l52)) - \(cs)\(String(format: "%.2f", h52))")
        }
        if let ahPrice = stock.displayPostMarketPrice, let ahChange = stock.displayPostMarketChange {
            lines.append("After Hours: \(cs)\(String(format: "%.2f", ahPrice)) (\(String(format: "%+.2f", ahChange)))")
        }
        if let pmPrice = stock.displayPreMarketPrice, let pmChange = stock.displayPreMarketChange {
            lines.append("Pre-Market: \(cs)\(String(format: "%.2f", pmPrice)) (\(String(format: "%+.2f", pmChange)))")
        }
        let overnightQuote = stock.displayQuote(includeExtendedHours: true)
        if overnightQuote.session == .overnight {
            lines.append("Overnight: \(cs)\(String(format: "%.2f", overnightQuote.price)) (\(String(format: "%+.2f", overnightQuote.change)))")
        }
        for lot in lots {
            let value = stock.displayPrice * lot.shares
            if let cost = lot.costBasis {
                let gain = (stock.displayPrice - cost) * lot.shares
                lines.append("Buy \(String(format: "%.2f", lot.shares)) @ \(cs)\(String(format: "%.2f", cost)) = \(cs)\(String(format: "%.2f", value)) (\(String(format: "%+.2f", gain)))")
            } else {
                lines.append("RSU \(String(format: "%.2f", lot.shares)) sh = \(cs)\(String(format: "%.2f", value))")
            }
        }
        if let state = stock.marketState {
            lines.append("Market: \(state)")
        }

        return lines.isEmpty ? displayName : lines.joined(separator: "\n")
    }

    /// Whether any market detail fields are available to show.
    private var hasMarketDetail: Bool {
        stock.displayDayHigh != nil || stock.display52WeekHigh != nil
            || stock.displayPostMarketPrice != nil || stock.displayPreMarketPrice != nil
            || stock.displayExtendedMarketPrice != nil
    }

    private var hasDetail: Bool {
        hasMarketDetail || !lots.isEmpty
    }

    var body: some View {
        let quote = stock.displayQuote(includeExtendedHours: includeExtendedHours)
        let currencySymbol = displayName == stock.symbol ? stock.currencySymbol : ""
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(displayName)
                            .font(.system(.body, design: .monospaced, weight: .semibold))
                        if hasAlert {
                            Image(systemName: "bell.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if !lots.isEmpty {
                            Image(systemName: "briefcase.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if !StockService.isOpen(stock) {
                            Image(systemName: "moon.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Outside regular market hours")
                        }
                    }
                    if displayName == stock.symbol {
                        Text(stock.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if stock.intradayPrices.count >= 2 {
                    SparklineView(prices: stock.intradayPrices, isPositive: quote.isPositive)
                        .frame(width: 50, height: 20)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(currencySymbol)\(String(format: "%.2f", quote.price))")
                        .font(.system(.body, design: .monospaced))

                    HStack(spacing: 2) {
                        Image(systemName: quote.isPositive ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.caption2)
                        Text(String(format: "%.2f (%.1f%%)", abs(quote.change), abs(quote.changePercent)))
                            .font(.caption)
                    }
                    .foregroundStyle(quote.isPositive ? .green : .red)
                }

                if hasDetail {
                    Button(action: { expanded.toggle() }) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show details")
                }
            }

            if expanded && hasDetail {
                detailView
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(tooltipText)
    }

    @ViewBuilder private var detailView: some View {
        let cs = stock.currencySymbol
        VStack(alignment: .leading, spacing: 2) {
            if let high = stock.displayDayHigh, let low = stock.displayDayLow {
                detailRow("Day", "\(cs)\(fmt(low)) – \(cs)\(fmt(high))")
            }
            if let h52 = stock.display52WeekHigh, let l52 = stock.display52WeekLow {
                detailRow("52-week", "\(cs)\(fmt(l52)) – \(cs)\(fmt(h52))")
            }
            if let ah = stock.displayPostMarketPrice, let ahc = stock.displayPostMarketChange {
                detailRow("After hours", "\(cs)\(fmt(ah)) (\(fmtSigned(ahc)))")
            }
            if let pm = stock.displayPreMarketPrice, let pmc = stock.displayPreMarketChange {
                detailRow("Pre-market", "\(cs)\(fmt(pm)) (\(fmtSigned(pmc)))")
            }
            let overnightQuote = stock.displayQuote(includeExtendedHours: true)
            if overnightQuote.session == .overnight {
                detailRow("Overnight", "\(cs)\(fmt(overnightQuote.price)) (\(fmtSigned(overnightQuote.change)))")
            }
            if hasMarketDetail && !lots.isEmpty {
                Divider()
                    .padding(.vertical, 2)
            }
            if !lots.isEmpty {
                Text("Holdings")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                ForEach(lots) { lot in
                    holdingLotView(lot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func holdingLotView(_ lot: StockService.Holding) -> some View {
        let currencySymbol = stock.currencySymbol
        let value = stock.displayPrice * lot.shares
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("\(lot.kind == .rsu ? "RSU" : "Purchase") · \(fmtShares(lot.shares)) sh")
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(currencySymbol)\(fmtMoney(value))")
                    .foregroundStyle(.secondary)
            }
            if let cost = lot.costBasis {
                let gain = (stock.displayPrice - cost) * lot.shares
                HStack {
                    Text("Cost \(currencySymbol)\(fmtMoney(cost)) / sh")
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("Return \(fmtSignedMoney(gain, symbol: currencySymbol))")
                        .foregroundStyle(gain >= 0 ? .green : .red)
                }
            }
        }
        .font(.caption2)
    }

    private func fmtMoney(_ value: Double) -> String {
        value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(2))
        )
    }

    private func fmtShares(_ value: Double) -> String {
        value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(0...4))
        )
    }

    private func fmtSignedMoney(_ value: Double, symbol: String) -> String {
        "\(value >= 0 ? "+" : "−")\(symbol)\(fmtMoney(abs(value)))"
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.tertiary)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.caption2)
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    private func fmtSigned(_ v: Double) -> String { String(format: "%+.2f", v) }
}


/// Re-fits the `MenuBarExtra(.window)` panel to its SwiftUI content height.
/// SwiftUI grows the panel when content (e.g. inline Settings) expands but does
/// not shrink it back, leaving an empty gap above the content. The target height
/// is supplied by a GeometryReader (the height SwiftUI has already committed for
/// the content) rather than read from the host view's `fittingSize`, which lags
/// on collapse and left the gap behind. We anchor the top edge (just below the
/// menu bar) and resize the panel to that height.
private final class WindowFittingView: NSView {
    var targetHeight: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitWindow()
    }

    func fitWindow() {
        guard let window, targetHeight > 1 else { return }
        guard abs(window.frame.height - targetHeight) > 0.5 else { return }
        let frame = window.frame
        window.setFrame(
            NSRect(x: frame.origin.x, y: frame.maxY - targetHeight, width: frame.size.width, height: targetHeight),
            display: true,
            animate: false
        )
    }
}

private struct MenuBarWindowResizer: NSViewRepresentable {
    var targetHeight: CGFloat

    func makeNSView(context: Context) -> WindowFittingView { WindowFittingView() }

    func updateNSView(_ nsView: WindowFittingView, context: Context) {
        nsView.targetHeight = targetHeight
        nsView.fitWindow()
    }
}
