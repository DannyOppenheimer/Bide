import Messages
import SwiftUI
import UIKit
import BideKit
import BideUI

/// Hosts SwiftUI screens and integrates them with Messages conversations and layouts.
/// The extension stages and renders tiles but delegates identity, server writes,
/// background work, and continuous ETA tracking to the container app.
final class MessagesViewController: MSMessagesAppViewController {

    private let profile = BideProfileStore()
    private let answers = LocalBideStore(defaults: .bideShared)
    /// Which conversations already hold a Bide, shared with the container app.
    private let sent = SentInviteStore()
    /// Pending invitations shared with the container app through the App Group.
    private let pending = PendingInviteStore()

    private lazy var model: MessagesModel = {
        // The extension may request only a foreground, one-shot location estimate.
        let model = MessagesModel(
            eta: MapKitETAEngine(locations: LocationService(background: false)),
            store: answers
        )
        model.onCompose = { [weak self] draft in self?.stage(draft) }
        model.onAccept = { [weak self] tile, mode, leaveAt in self?.accept(tile, mode: mode, leaveAt: leaveAt) }
        model.onDecline = { [weak self] tile in self?.decline(tile) }
        model.onTrack = { [weak self] tile in self?.track(tile) }
        model.onNeedsRoom = { [weak self] in self?.requestPresentationStyle(.expanded) }
        model.onNeedsAccount = { [weak self] in self?.openApp() }
        model.onNeedsApp = { [weak self] in self?.openApp() }
        return model
    }()

    private var host: UIHostingController<AnyView>?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(BideColor.background)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        render(for: conversation)
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        render(for: conversation)
        // Expand the drawer to fit the response form.
        if case .respond = model.screen {
            requestPresentationStyle(.expanded)
        }
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        render(for: conversation)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        guard let conversation = activeConversation else { return }
        render(for: conversation)
    }

    /// Returns a deterministic transcript bubble size without external work.
    override func contentSizeThatFits(_ size: CGSize) -> CGSize {
        guard presentationStyle == .transcript, let host else { return size }
        let fitted = host.sizeThatFits(in: CGSize(width: size.width, height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: min(fitted.height, size.height))
    }

    // MARK: - Rendering

    private func render(for conversation: MSConversation) {
        let message = conversation.selectedMessage
        let tile = message?.url.flatMap(BideTileMessage.init(url:))
        let role = ParticipantRole(
            senderIdentifier: message?.senderParticipantIdentifier ?? ParticipantRole.unassignedIdentifier,
            localIdentifier: conversation.localParticipantIdentifier
        )

        if presentationStyle == .transcript {
            // Transcript rendering is static and performs no external work.
            guard let tile else { return }
            present(
                AnyView(
                    TranscriptView(
                        tile: tile,
                        senderName: tile.senderName,
                        role: role,
                        localAnswer: answers.answer(for: tile.invite.bideID)
                    )
                )
            )
            return
        }

        model.conversationKey = conversation.bideConversationKey
        model.present(tile: tile, role: role)
        present(
            AnyView(
                ExtensionRootView(model: model, isExpanded: presentationStyle == .expanded)
            )
        )
    }

    /// Reuses the hosting controller while replacing its SwiftUI root view.
    private func present(_ view: AnyView) {
        if let host {
            host.rootView = view
            return
        }

        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    // MARK: - Actions

    /// Stages a new tile in Messages and records it for later app reconciliation.
    /// The user sends it manually; conflict checks wait until someone accepts.
    private func stage(_ draft: BidePlanDraft) {
        guard
            let conversation = activeConversation,
            let invite = draft.invite()
        else { return }

        // Enforce a durable identity at the point where a tile is staged.
        guard profile.isSignedInWithApple else {
            openApp()
            return
        }

        let tile = BideTileMessage(invite: invite, senderName: profile.displayName)

        // Sending an invitation does not yet commit the sender to a journey.
        insert(tile, summary: "Meet at \(invite.destinationName)?", into: conversation) { [weak self] in
            self?.requestPresentationStyle(.compact)
        }

        // The container app claims this invitation after a recipient accepts.
        pending.add(PendingInvite(invite: invite, mode: draft.mode))

        // Occupy the conversation, so a second tile cannot be sent to the same
        // people until this one is ended or expires.
        sent.record(
            SentInvite(
                bideID: invite.bideID,
                conversationKey: conversation.bideConversationKey,
                destinationName: invite.destinationName,
                scheduledFor: invite.scheduledFor
            )
        )
    }

    private func accept(_ tile: BideTileMessage, mode: TravelMode, leaveAt: Date?) {
        guard let conversation = activeConversation else { return }

        let answered = BideTileMessage(
            invite: tile.invite,
            answer: .accepted,
            leaveAt: leaveAt,
            senderName: profile.displayName
        )
        insert(answered, summary: "On the way to \(tile.invite.destinationName)", into: conversation)
        open(answered.appURL(), action: .accept, mode: mode)
    }

    /// Starts following a journey without inserting a watcher response into the thread.
    private func track(_ tile: BideTileMessage) {
        let watching = BideTileMessage(
            invite: tile.invite,
            answer: .watching,
            senderName: tile.senderName,
            isTrackingInvite: true
        )
        answers.record(LocalAnswer(status: .watching, mode: .walking), for: tile.invite.bideID)
        open(watching.appURL(), action: .track, mode: .walking)
    }

    /// Opens the container app for sign-in without attaching an invitation.
    private func openApp() {
        guard let url = URL(string: "\(BideInvite.appScheme)://") else { return }
        extensionContext?.open(url)
    }

    private func decline(_ tile: BideTileMessage) {
        guard let conversation = activeConversation else { return }

        let answered = BideTileMessage(
            invite: tile.invite,
            answer: .declined,
            senderName: profile.displayName
        )
        // Declining requires no container-app work.
        insert(answered, summary: "Can't make it to \(tile.invite.destinationName)", into: conversation) { [weak self] in
            self?.requestPresentationStyle(.compact)
        }
    }

    // MARK: - Messages plumbing

    /// Stages a message using the current session so replies replace the existing bubble.
    private func insert(
        _ tile: BideTileMessage,
        summary: String,
        into conversation: MSConversation,
        then completion: (() -> Void)? = nil
    ) {
        let message = MSMessage(session: conversation.selectedMessage?.session ?? MSSession())
        message.url = tile.webURL()
        message.summaryText = summary
        message.layout = layout(for: tile)

        conversation.insert(message) { error in
            if let error {
                assertionFailure("Failed to insert tile: \(error)")
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Creates a live layout with a snapshot fallback for unsupported devices.
    private func layout(for tile: BideTileMessage) -> MSMessageLayout {
        let template = MSMessageTemplateLayout()
        template.image = tileSnapshot(for: tile)
        template.caption = tile.invite.destinationName
        template.subcaption = tile.isTrackingInvite
            ? BideFormat.soloSchedule(tile.invite.scheduledFor)
            : BideFormat.schedule(tile.invite.scheduledFor)
        return MSMessageLiveLayout(alternateLayout: template)
    }

    /// Renders the tile snapshot used by the fallback layout.
    private func tileSnapshot(for tile: BideTileMessage) -> UIImage? {
        let view = BideTileView.transcript(
            invite: tile.invite,
            senderName: tile.senderName,
            role: .recipient,
            answer: tile.answer,
            leaveAt: tile.leaveAt,
            isTrackingInvite: tile.isTrackingInvite
        )
        .frame(width: 300)
        .padding(8)
        .background(BideColor.background)

        let renderer = ImageRenderer(content: view)
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage
    }

    /// Action the container app should perform after handoff.
    private enum HandOff: String {
        case accept
        /// Joins as a watcher without starting a local ETA.
        case track
    }

    private func open(_ url: URL, action: HandOff, mode: TravelMode) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var items = components.percentEncodedQueryItems ?? []
        items.append(URLQueryItem(name: "action", value: action.rawValue))
        items.append(URLQueryItem(name: "mode", value: mode.rawValue))
        components.percentEncodedQueryItems = items

        guard let handOff = components.url else { return }
        extensionContext?.open(handOff) { [weak self] opened in
            guard opened else { return }
            DispatchQueue.main.async { self?.requestPresentationStyle(.compact) }
        }
    }
}

extension MSConversation {

    /// Stable, opaque thread key built from sorted, app-scoped participant IDs.
    /// Returns an empty key until Messages identifies the recipients.
    var bideConversationKey: String {
        remoteParticipantIdentifiers
            .map(\.uuidString)
            .sorted()
            .joined(separator: "+")
    }
}
