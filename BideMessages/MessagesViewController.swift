import Messages
import SwiftUI
import UIKit
import BideKit
import BideUI

/// The Messages extension.
///
/// View-only, per CLAUDE.md: no background work, no push, no ActivityKit, and
/// no writes to Bide's server. It does exactly three things — stage a tile in
/// the conversation, let a recipient answer one, and draw the tile in the
/// transcript — and hands anything that needs a real identity or a running ETA
/// to the container app over `bide://`.
///
/// Everything visible is SwiftUI from BideUI, hosted here; this class owns only
/// the parts that are genuinely `Messages`: conversations, message layouts, and
/// the compact/expanded/transcript presentation styles.
final class MessagesViewController: MSMessagesAppViewController {

    private let profile = BideProfileStore()
    private let answers = LocalBideStore(defaults: .bideShared)

    private lazy var model: MessagesModel = {
        // Foreground-only location: the tile shows "36 minutes from this
        // location" while someone is looking at it. An extension must never
        // ask for the background kind, hence `background: false`.
        let model = MessagesModel(
            eta: MapKitETAEngine(locations: LocationService(background: false)),
            store: answers
        )
        model.onCompose = { [weak self] draft in self?.stage(draft) }
        model.onAccept = { [weak self] tile, mode, leaveAt in self?.accept(tile, mode: mode, leaveAt: leaveAt) }
        model.onDecline = { [weak self] tile in self?.decline(tile) }
        model.onNeedsRoom = { [weak self] in self?.requestPresentationStyle(.expanded) }
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
        // Answering needs room the drawer doesn't have.
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

    /// Sizes the bubble in the transcript. Messages asks before laying the
    /// thread out, so this has to be cheap and deterministic.
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
            // Drawn by Messages inside the bubble: static, non-interactive,
            // and never allowed to fetch anything.
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

        model.present(tile: tile, role: role)
        present(
            AnyView(
                ExtensionRootView(model: model, isExpanded: presentationStyle == .expanded)
            )
        )
    }

    /// Swaps the hosted SwiftUI tree, reusing the hosting controller so the
    /// view's own state survives a re-render.
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

    /// Puts a new tile in the input field. An extension may stage a message;
    /// only the person can send it.
    private func stage(_ draft: BidePlanDraft) {
        guard
            let conversation = activeConversation,
            let invite = draft.invite()
        else { return }

        let tile = BideTileMessage(invite: invite, senderName: profile.displayName)
        // The creator's own answer, so their transcript shows the sent state
        // rather than an invitation addressed to themselves.
        answers.record(LocalAnswer(status: .accepted, mode: draft.mode), for: invite.bideID)

        insert(tile, summary: "Meet at \(invite.destinationName)?", into: conversation) { [weak self] in
            self?.requestPresentationStyle(.compact)
        }

        // The bide itself is created server-side by the container app, which
        // holds the identity every row-level security policy is written
        // against. The extension deliberately owns no account of its own.
        open(tile.appURL(), action: .create, mode: draft.mode)
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

    private func decline(_ tile: BideTileMessage) {
        guard let conversation = activeConversation else { return }

        let answered = BideTileMessage(
            invite: tile.invite,
            answer: .declined,
            senderName: profile.displayName
        )
        // No hand-off to the app: declining means there's nothing to track.
        insert(answered, summary: "Can't make it to \(tile.invite.destinationName)", into: conversation) { [weak self] in
            self?.requestPresentationStyle(.compact)
        }
    }

    // MARK: - Messages plumbing

    /// Builds the message and stages it in the input field, keeping the same
    /// `MSSession` so an answer updates the existing bubble instead of
    /// stacking a new one under it.
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

    /// A live layout, so the bubble is Bide's own tile rather than a stock
    /// caption-under-image card. The alternate is what devices without the app
    /// — and Messages on the Mac — fall back to, so it's rendered from the same
    /// SwiftUI view rather than being a second design.
    private func layout(for tile: BideTileMessage) -> MSMessageLayout {
        let template = MSMessageTemplateLayout()
        template.image = tileSnapshot(for: tile)
        template.caption = tile.invite.destinationName
        template.subcaption = BideFormat.schedule(tile.invite.scheduledFor)
        return MSMessageLiveLayout(alternateLayout: template)
    }

    /// Renders the tile to an image for the fallback layout.
    private func tileSnapshot(for tile: BideTileMessage) -> UIImage? {
        let view = BideTileView.transcript(
            invite: tile.invite,
            senderName: tile.senderName,
            role: .recipient,
            answer: tile.answer,
            leaveAt: tile.leaveAt
        )
        .frame(width: 300)
        .padding(8)
        .background(BideColor.background)

        let renderer = ImageRenderer(content: view)
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage
    }

    /// What the container app should do once it opens.
    private enum HandOff: String {
        case create
        case accept
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
