import Foundation

/// One person's standing in a bide.
///
/// Carries an arrival *timestamp* and nothing else about where they are. There
/// is no location here because there is no location column in the database —
/// see the privacy invariant at the top of the schema migration.
public struct Participant: Codable, Equatable, Sendable, Identifiable {

    public let userID: UUID
    /// What they call themselves. Nil for someone who never signed in and
    /// never set one; the UI falls back to a placeholder rather than inventing
    /// a name.
    public let displayName: String?
    public let mode: TravelMode
    /// When they expect to arrive. Null until their first ETA is anchored.
    public let etaTimestamp: Date?
    /// The first ETA we ever recorded for them. Everything later is graded
    /// against this to decide whether a time shows green, yellow, or red.
    public let baselineETA: Date?
    public let status: ParticipantStatus
    public let updatedAt: Date

    public var id: UUID { userID }

    public init(
        userID: UUID,
        displayName: String? = nil,
        mode: TravelMode,
        etaTimestamp: Date? = nil,
        baselineETA: Date? = nil,
        status: ParticipantStatus = .invited,
        updatedAt: Date = Date()
    ) {
        self.userID = userID
        self.displayName = displayName
        self.mode = mode
        self.etaTimestamp = etaTimestamp
        self.baselineETA = baselineETA
        self.status = status
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case mode
        case etaTimestamp = "eta_timestamp"
        case baselineETA = "baseline_eta"
        case status
        case updatedAt = "updated_at"
    }

    /// Whether they have set off. Someone who has accepted but whose ETA
    /// hasn't been anchored yet is still at home — that's the "Waiting..."
    /// state on the tile and in the Live Activity.
    public var hasLeft: Bool { status == .accepted && etaTimestamp != nil }

    /// How this person's current estimate compares with the one they started
    /// from. Nil until there are both to compare.
    public var delayGrade: DelayGrade? {
        guard let etaTimestamp, let baselineETA else { return nil }
        return DelayGrade(projected: etaTimestamp, planned: baselineETA)
    }
}

/// A bide and everyone in it — what the container app renders and what the ETA
/// engine works from.
public struct BideState: Codable, Equatable, Sendable, Identifiable {

    public let bideID: UUID
    public let destinationName: String
    public let lat: Double
    public let lng: Double
    /// When everyone is due. Nil for an asap bide.
    public let scheduledFor: Date?
    public let arrivalStyle: ArrivalStyle
    /// A bide with an audience rather than participants: the creator is going
    /// somewhere, and anyone else in it is only watching.
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

    /// A row fetched without its embedded participants still decodes, as an
    /// empty roster rather than a failure.
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

    /// The shareable form of this bide — the tile URL model.
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

    /// Everyone but you — in a two-person bide, the person you're meeting.
    public func participants(besides userID: UUID) -> [Participant] {
        participants.filter { $0.userID != userID }
    }

    /// Everyone still expected to turn up.
    public var travellers: [Participant] {
        participants.filter { $0.status.isTravelling }
    }

    /// Whether anyone still owes an answer. The bide holds off starting until
    /// this is false — or until the furthest person has to leave, whichever
    /// comes first.
    public var isAwaitingAnswers: Bool {
        participants.contains { $0.status.isAwaitingAnswer }
    }

    /// True once everyone who said yes has arrived, which is what retires the
    /// tile and ends the Live Activity.
    public var isComplete: Bool {
        let answered = participants.filter { $0.status != .declined }
        return !answered.isEmpty && answered.allSatisfy { $0.status == .arrived }
    }

    /// The person with the longest journey still ahead of them. In an
    /// ``ArrivalStyle/together`` bide this is who everyone else waits on.
    public func furthestTraveller(now: Date = Date()) -> Participant? {
        travellers
            .filter { $0.etaTimestamp != nil }
            .max { ($0.etaTimestamp ?? now) < ($1.etaTimestamp ?? now) }
    }

    /// When this bide is aiming for: the time that was agreed, or — for an
    /// asap bide — the latest ETA among the people still travelling.
    public func targetArrival(now: Date = Date()) -> Date? {
        scheduledFor ?? furthestTraveller(now: now)?.etaTimestamp
    }

    /// The slice of the day this bide occupies for `userID`, used to spot a
    /// clash with another bide. Nil until there's enough to compute one.
    public func travelWindow(for userID: UUID, now: Date = Date()) -> TravelWindow? {
        guard let arrival = targetArrival(now: now) else { return nil }
        guard let participant = participant(userID), let eta = participant.etaTimestamp else {
            // No ETA of their own yet: treat the journey as instantaneous so
            // the bide still occupies its arrival moment.
            return TravelWindow(leaveAt: arrival, arriveAt: arrival)
        }
        return TravelWindow(arriveAt: arrival, travelTime: eta.timeIntervalSince(now))
    }

    public var conflictCandidate: ScheduleConflict.Candidate? {
        guard let window = travelWindow(for: createdBy) else { return nil }
        return ScheduleConflict.Candidate(id: bideID, destinationName: destinationName, window: window)
    }
}
