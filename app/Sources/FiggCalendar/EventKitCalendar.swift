import EventKit
import Foundation

/// Reads the user's macOS calendars through EventKit. Read-only: figg never
/// creates or edits events. Requires NSCalendarsFullAccessUsageDescription
/// and the com.apple.security.personal-information.calendars entitlement.
public final class EventKitCalendar: CalendarProvider, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func events(from: Date, to: Date) async -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                attendees: Self.attendeeNames(event),
                isAllDay: event.isAllDay)
        }
    }

    /// Human attendees by name, organizer first, rooms and lists left out.
    /// Declined events still list everyone; good enough for prompts.
    static func attendeeNames(_ event: EKEvent) -> [String] {
        var names: [String] = []
        if let organizer = event.organizer, organizer.participantType == .person, let name = displayName(organizer) {
            names.append(name)
        }
        for p in event.attendees ?? [] where p.participantType == .person {
            if let name = displayName(p), !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static func displayName(_ participant: EKParticipant) -> String? {
        let name = participant.name?.trimmingCharacters(in: .whitespaces) ?? ""
        if !name.isEmpty, !name.contains("@") { return name }
        // No real name: fall back to the mailto address's local part.
        let mail = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        let local = mail.split(separator: "@").first.map(String.init) ?? (name.isEmpty ? mail : name)
        return local.isEmpty ? nil : local
    }
}
