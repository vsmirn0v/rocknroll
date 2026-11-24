import ConferenceCore
import Foundation
import SwiftUI

@MainActor
private final class ScrubberDateFormatterCache {
    static let shared = ScrubberDateFormatterCache()

    private struct Key: Equatable {
        let localeID: String
        let calendarID: Calendar.Identifier
        let timeZoneID: String
    }

    private var currentKey: Key?
    private let monthYearFormatter = DateFormatter()
    private let fullDayFormatter = DateFormatter()
    private let weekdayShortFormatter = DateFormatter()

    private func ensureConfigured(locale: Locale, calendar: Calendar) {
        let key = Key(localeID: locale.identifier, calendarID: calendar.identifier, timeZoneID: calendar.timeZone.identifier)
        guard currentKey != key else { return }
        currentKey = key

        var localizedCal = calendar
        localizedCal.locale = locale

        monthYearFormatter.locale = locale
        monthYearFormatter.calendar = localizedCal
        monthYearFormatter.timeZone = calendar.timeZone
        monthYearFormatter.formattingContext = .standalone
        monthYearFormatter.setLocalizedDateFormatFromTemplate("LLLLy")

        fullDayFormatter.locale = locale
        fullDayFormatter.calendar = localizedCal
        fullDayFormatter.timeZone = calendar.timeZone
        fullDayFormatter.dateStyle = .long
        fullDayFormatter.timeStyle = .none

        weekdayShortFormatter.locale = locale
        weekdayShortFormatter.calendar = localizedCal
        weekdayShortFormatter.timeZone = calendar.timeZone
        weekdayShortFormatter.setLocalizedDateFormatFromTemplate("E")
    }

    func monthYear(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        ensureConfigured(locale: locale, calendar: calendar)
        return monthYearFormatter.string(from: date).capitalized(with: locale)
    }

    func fullDay(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        ensureConfigured(locale: locale, calendar: calendar)
        return fullDayFormatter.string(from: date)
    }

    func weekdayShort(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        ensureConfigured(locale: locale, calendar: calendar)
        return weekdayShortFormatter.string(from: date)
    }
}

public struct CompactCalendarDayMarker: Equatable, Sendable {
    public var primaryCount: Int
    public var secondaryCount: Int
    public var hasAccent: Bool

    public init(primaryCount: Int = 0, secondaryCount: Int = 0, hasAccent: Bool = false) {
        self.primaryCount = primaryCount
        self.secondaryCount = secondaryCount
        self.hasAccent = hasAccent
    }

    public var totalCount: Int { primaryCount + secondaryCount }
}

public struct CompactMonthScrubberView: View {
    @Binding public var displayedMonth: Date
    public let selectedDate: Date?
    public let markersByDay: [Date: CompactCalendarDayMarker]
    public var calendar: Calendar
    public var allowEmptyDaySelection: Bool
    public var primaryDotColor: Color
    public var secondaryDotColor: Color
    public let onSelectDay: (Date) -> Void
    public var onToday: (() -> Void)?

    @Environment(\.locale) private var locale

    public init(
        displayedMonth: Binding<Date>,
        selectedDate: Date?,
        markersByDay: [Date: CompactCalendarDayMarker],
        calendar: Calendar = .current,
        allowEmptyDaySelection: Bool = false,
        primaryDotColor: Color = .orange,
        secondaryDotColor: Color = .green,
        onSelectDay: @escaping (Date) -> Void,
        onToday: (() -> Void)? = nil
    ) {
        self._displayedMonth = displayedMonth
        self.selectedDate = selectedDate
        self.markersByDay = markersByDay
        self.calendar = calendar
        self.allowEmptyDaySelection = allowEmptyDaySelection
        self.primaryDotColor = primaryDotColor
        self.secondaryDotColor = secondaryDotColor
        self.onSelectDay = onSelectDay
        self.onToday = onToday
    }

    private var monthStart: Date {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: displayedMonth)
    }

    private var weekdayHeaders: [String] {
        var localizedCal = calendar
        localizedCal.locale = locale
        let symbols = localizedCal.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let offset = max(0, min(6, calendar.firstWeekday - 1))
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private var gridCells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let firstWeekdayOfMonth = calendar.component(.weekday, from: monthStart)
        let leadingEmpty = (firstWeekdayOfMonth - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leadingEmpty)
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) {
                cells.append(calendar.startOfDay(for: date))
            }
        }
        while cells.count % 7 != 0 {
            cells.append(nil)
        }
        return cells
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    shiftMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .flipsForRightToLeftLayoutDirection(true)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Previous month"))

                Text(ScrubberDateFormatterCache.shared.monthYear(monthStart, locale: locale, calendar: calendar))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                Button {
                    shiftMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .flipsForRightToLeftLayoutDirection(true)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Next month"))

                Button(L("Today")) {
                    let today = calendar.startOfDay(for: Date())
                    displayedMonth = today
                    if let onToday {
                        onToday()
                    } else {
                        onSelectDay(today)
                    }
                }
                .font(.caption2.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(weekdayHeaders.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(Array(gridCells.enumerated()), id: \.offset) { _, dayDate in
                    if let dayDate {
                        dayCell(dayDate)
                    } else {
                        Color.clear.frame(height: 28)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func dayCell(_ dayDate: Date) -> some View {
        let dayStart = calendar.startOfDay(for: dayDate)
        let marker = markersByDay[dayStart]
        let hasItems = (marker?.totalCount ?? 0) > 0
        let isEnabled = allowEmptyDaySelection || hasItems
        let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: dayStart) } ?? false
        let isToday = calendar.isDateInToday(dayStart)
        let dayNumber = calendar.component(.day, from: dayStart)

        return Button {
            onSelectDay(dayStart)
        } label: {
            VStack(spacing: 2) {
                Text("\(dayNumber)")
                    .font(.caption2.weight(isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : (isEnabled ? .primary : .secondary.opacity(0.5)))
                    .frame(maxWidth: .infinity)

                dotRow(for: marker, isSelected: isSelected)
                    .frame(height: 5)
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.14) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isToday && !isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel(for: dayStart, marker: marker))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func dotRow(for marker: CompactCalendarDayMarker?, isSelected: Bool) -> some View {
        if let marker, marker.totalCount > 0 {
            HStack(spacing: 2) {
                if marker.secondaryCount > 0 && marker.primaryCount > 0 {
                    Circle()
                        .fill(isSelected ? .white : secondaryDotColor)
                        .frame(width: 4, height: 4)
                    Circle()
                        .fill(isSelected ? .white : primaryDotColor)
                        .frame(width: 4, height: 4)
                } else {
                    let dotColor: Color = isSelected ? .white : (marker.secondaryCount > 0 ? secondaryDotColor : primaryDotColor)
                    Circle()
                        .fill(dotColor)
                        .frame(width: 4, height: 4)
                    if marker.totalCount > 1 {
                        Circle()
                            .fill(dotColor.opacity(0.8))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        } else {
            Color.clear.frame(width: 4, height: 4)
        }
    }

    private func shiftMonth(by delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: monthStart) {
            displayedMonth = next
        }
    }

    private func accessibilityLabel(for day: Date, marker: CompactCalendarDayMarker?) -> String {
        let formatted = ScrubberDateFormatterCache.shared.fullDay(day, locale: locale, calendar: calendar)
        let count = marker?.totalCount ?? 0
        if count == 0 {
            return formatted
        }
        return L("%@ · %ld meetings", formatted, count)
    }
}

public struct CompactWeekStripView: View {
    public let referenceDate: Date
    public let selectedDate: Date?
    public let markersByDay: [Date: CompactCalendarDayMarker]
    public var calendar: Calendar
    public var allowEmptyDaySelection: Bool
    public let onSelectDay: (Date) -> Void

    @Environment(\.locale) private var locale

    public init(
        referenceDate: Date = Date(),
        selectedDate: Date?,
        markersByDay: [Date: CompactCalendarDayMarker],
        calendar: Calendar = .current,
        allowEmptyDaySelection: Bool = false,
        onSelectDay: @escaping (Date) -> Void
    ) {
        self.referenceDate = referenceDate
        self.selectedDate = selectedDate
        self.markersByDay = markersByDay
        self.calendar = calendar
        self.allowEmptyDaySelection = allowEmptyDaySelection
        self.onSelectDay = onSelectDay
    }

    private var weekDays: [Date] {
        let anchor = calendar.startOfDay(for: selectedDate ?? referenceDate)
        let weekday = calendar.component(.weekday, from: anchor)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -offset, to: anchor) else {
            return [anchor]
        }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
            .map { calendar.startOfDay(for: $0) }
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(weekDays, id: \.self) { day in
                let marker = markersByDay[day]
                let hasItems = (marker?.totalCount ?? 0) > 0
                let isEnabled = allowEmptyDaySelection || hasItems
                let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                let isToday = calendar.isDateInToday(day)

                Button {
                    onSelectDay(day)
                } label: {
                    VStack(spacing: 3) {
                        Text(ScrubberDateFormatterCache.shared.weekdayShort(day, locale: locale, calendar: calendar))
                            .font(.caption2)
                            .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.caption.weight(isSelected || isToday ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : (isEnabled ? .primary : .secondary.opacity(0.5)))
                        Circle()
                            .fill(hasItems ? (isSelected ? Color.white : Color.accentColor) : Color.clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.14) : Color.clear))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}
