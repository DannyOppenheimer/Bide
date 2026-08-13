import Foundation

/// One participant's state. It stores an arrival estimate, never their location.
public struct Participant: Codable, Equatable, Sendable, Identifiable {

    public let userID: UUID
    /// User-provided display name, or `nil` if none is set.
    public let displayName: String?
    public let mode: TravelMode
    /// Anchored arrival estimate. It becomes fixed only after ``leftAt`` is set.
    public let etaTimestamp: Date?
    /// Initial arrival estimate used to grade later delays.
    public let baselineETA: Date?
    /// Most recently measured journey duration. This is not location data.
    public let travelTime: TimeInterval?
    /// Time the device detected departure from its private, on-device origin.
    public let leftAt: Date?
    public let status: ParticipantStatus
    public let updatedAt: Date

    public var id: UUID { userID }

    public init(
        userID: UUID,
        displayName: String? = nil,
        mode: TravelMode,
        etaTimestamp: Date? = nil,
        baselineETA: Date? = nil,
        travelTime: TimeInterval? = nil,
        leftAt: Date? = nil,
        status: ParticipantStatus = .invited,
        updatedAt: Date = Date()
    ) {
        self.userID = userID
        self.displayName = displayName
        self.mode = mode
        self.etaTimestamp = etaTimestamp
        self.baselineETA = baselineETA
        self.travelTime = travelTime
        self.leftAt = leftAt
        self.status = status
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case mode
        case etaTimestamp = "eta_timestamp"
        case baselineETA = "baseline_eta"
        case travelTime = "travel_seconds"
        case leftAt = "left_at"
        case status
        case updatedAt = "updated_at"
    }

    /// Whether an attending participant has departed.
    public var hasLeft: Bool { status.isTravelling && leftAt != nil }

    /// Current journey duration, including a fallback for rows created before
    /// `travel_seconds` was added.
    public var journey: TimeInterval? {
        if let travelTime { return max(0, travelTime) }
        guard let etaTimestamp else { return nil }
        return max(0, etaTimestamp.timeIntervalSince(updatedAt))
    }

    /// Expected arrival at `now`. Before departure, it remains relative to the clock.
    public func arrival(now: Date = Date()) -> Date? {
        guard status.isTravelling else { return nil }
        if hasLeft { return etaTimestamp }
        return journey.map { now.addingTimeInterval($0) }
    }

    /// Remaining duration, counting down only after departure.
    public func remainingTravel(now: Date = Date()) -> TimeInterval? {
        guard status.isTravelling else { return nil }
        if hasLeft, let etaTimestamp { return max(0, etaTimestamp.timeIntervalSince(now)) }
        return journey
    }

    /// Delay relative to the baseline ETA. Delay grading begins after departure.
    public var delayGrade: DelayGrade? {
        guard let etaTimestamp, let baselineETA else { return nil }
        guard hasLeft || status == .arrived else { return .onSchedule }
        return DelayGrade(projected: etaTimestamp, planned: baselineETA)
    }
}

/// A bide and its participant state.
public struct BideState: Codable, Equatable, Sendable, Identifiable {

    public let bideID: UUID
    public let destinationName: String
    public let lat: Double
    public let lng: Double
    /// Target arrival time, or `nil` for an ASAP bide.
    public let scheduledFor: Date?
    public let arrivalStyle: ArrivalStyle
    /// Whether non-creators follow the creator instead of attending.
    public let isSolo: Bool
    public let createdAt: Date
    public let createdBy: UUID
    public let participants: [Participant]

    public var id: UUID { bideID }

    public init(
        bideID: UUID,
        destinationName: String,
        lat: Double,
        lng: Double,
        scheduledFor: Date? = nil,
        arrivalStyle: ArrivalStyle = .onTime,
        isSolo: Bool = false,
        createdAt: Date,
        createdBy: UUID,
        participants: [Participant]
    ) {
        self.bideID = bideID
        self.destinationName = destinationName
        self.lat = lat
        self.lng = lng
        self.scheduledFor = scheduledFor
        self.arrivalStyle = arrivalStyle
        self.isSolo = isSolo
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.participants = participants
    }

    enum CodingKeys: String, CodingKey {
        case bideID = "id"
        case destinationName = "destination_name"
        case lat
        case lng
        case scheduledFor = "scheduled_for"
        case arrivalStyle = "arrival_style"
        case isSolo = "is_solo"
        case createdAt = "created_at"
        case createdBy = "created_by"
        case participants
    }

    /// Decodes missing embedded participants as an empty list.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bideID = try container.decode(UUID.self, forKey: .bideID)
        destinationName = try container.decode(String.self, forKey: .destinationName)
        lat = try container.decode(Double.self, forKey: .lat)
        lng = try container.decode(Double.self, forKey: .lng)
        scheduledFor = try container.decodeIfPresent(Date.self, forKey: .scheduledFor)
        arrivalStyle = try container.decodeIfPresent(ArrivalStyle.self, forKey: .arrivalStyle) ?? .onTime
        isSolo = try container.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        createdBy = try container.decode(UUID.self, forKey: .createdBy)
        participants = try container.decodeIfPresent([Participant].self, forKey: .participants) ?? []
    }
}

extension BideState {

    /// The invitation data used to build a shareable tile URL.
    public var invite: BideInvite {
        BideInvite(
            bideID: bideID,
            destinationName: destinationName,
            lat: lat,
            lng: lng,
            scheduledFor: scheduledFor,
            arrivalStyle: arrivalStyle,
            createdAt: createdAt
        )
    }

    public func participant(_ userID: UUID) -> Participant? {
        participants.first { $0.userID == userID }
    }

    /// Returns every participant except the specified user.
    public func participants(besides userID: UUID) -> [Participant] {
        participants.filter { $0.userID != userID }
    }

    /// Participants currently travelling to the destination.
    public var travellers: [Participant] {
        participants.filter { $0.status.isTravelling }
    }

    /// Participants shown in attendee rosters, excluding declines and watchers.
    public var roster: [Participant] {
        participants.filter { $0.status != .declined && !$0.status.isWatching }
    }

    /// Participants following the journey without attending.
    public var watchers: [Participant] {
        participants.filter { $0.status.isWatching }
    }

    /// Whether the specified user follows the journey without attending.
    public func isWatching(_ userID: UUID?) -> Bool {
        guard let userID else { return false }
        return participant(userID)?.status.isWatching == true
    }

    /// Whether any invitation remains unanswered.
    public var isAwaitingAnswers: Bool {
        participants.contains { $0.status.isAwaitingAnswer }
    }

    /// Whether every roster participant has arrived. Watchers do not affect completion.
    public var isComplete: Bool {
        let answered = roster
        return !answered.isEmpty && answered.allSatisfy { $0.status == .arrived }
    }

    /// Maximum lifetime after the scheduled time, or creation time for ASAP bides.
    public static let lifetime: TimeInterval = 6 * 60 * 60

    /// Whether the bide has exceeded its lifetime.
    public func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(scheduledFor ?? createdAt) > Self.lifetime
    }

    /// Returns the traveller with the latest projected arrival.
    public func furthestTraveller(now: Date = Date()) -> Participant? {
        travellers
            .filter { $0.arrival(now: now) != nil }
            .max { ($0.arrival(now: now) ?? now) < ($1.arrival(now: now) ?? now) }
    }

    /// Returns the scheduled arrival or latest traveller arrival for an ASAP bide.
    public func targetArrival(now: Date = Date()) -> Date? {
        scheduledFor ?? furthestTraveller(now: now)?.arrival(now: now)
    }

    /// Returns the user's occupied travel window, if an arrival can be calculated.
    public func travelWindow(for userID: UUID, now: Date = Date()) -> TravelWindow? {
        guard let arrival = targetArrival(now: now) else { return nil }
        guard let travelTime = participant(userID)?.remainingTravel(now: now) else {
            // Without a personal ETA, reserve the shared arrival instant.
            return TravelWindow(leaveAt: arrival, arriveAt: arrival)
        }
        return TravelWindow(arriveAt: arrival, travelTime: travelTime)
    }

    public var conflictCandidate: ScheduleConflict.Candidate? {
        guard let window = travelWindow(for: createdBy) else { return nil }
        return ScheduleConflict.Candidate(id: bideID, destination: destination, window: window)
    }
}
