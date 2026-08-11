import UIKit
import Messages
import BideKit

/// The Messages extension's only screen. It is view-only per CLAUDE.md — no
/// background work, no push registration, no location — so it just renders
/// whatever `MeetupState` it can decode from the conversation and lets the
/// user either propose a new tile or accept one that's already there.
final class MessagesViewController: MSMessagesAppViewController {

    // MARK: - UI

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.numberOfLines = 0
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    private let etaLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        return label
    }()

    private lazy var detailStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [subtitleLabel, etaLabel])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }()

    private lazy var actionButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(actionButtonTapped), for: .touchUpInside)
        return button
    }()

    private lazy var rootStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [titleLabel, detailStackView, actionButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // MARK: - State

    private enum Mode {
        /// No message selected — offer to send a new tile.
        case compose
        /// A tile from the other participant, still open — offer to accept it.
        case respond(MeetupState, session: MSSession?)
        /// The local user's own tile, or one that's already been accepted —
        /// nothing to do here but show where things stand.
        case status(MeetupState)
    }

    private var mode: Mode = .compose {
        didSet { render() }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        view.addSubview(rootStackView)
        NSLayoutConstraint.activate([
            rootStackView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            rootStackView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            rootStackView.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
        ])

        render()
    }

    // MARK: - MSMessagesAppViewController

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        configureMode(for: conversation, selected: conversation.selectedMessage)
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        configureMode(for: conversation, selected: message)
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        configureMode(for: conversation, selected: message)
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        applyLayout(for: presentationStyle)
    }

    // MARK: - Mode

    private func configureMode(for conversation: MSConversation, selected message: MSMessage?) {
        guard
            let message,
            let url = message.url,
            let state = MeetupState(url: url)
        else {
            mode = .compose
            return
        }

        if message.senderParticipantIdentifier == conversation.localParticipantIdentifier {
            // We sent this one ourselves — nothing to accept.
            mode = .status(state)
        } else if state.status == .proposed {
            mode = .respond(state, session: message.session)
        } else {
            mode = .status(state)
        }
    }

    // MARK: - Rendering

    private func render() {
        switch mode {
        case .compose:
            titleLabel.text = "Meet up?"
            subtitleLabel.text = MeetupState.placeholder.placeName
            etaLabel.text = "\(MeetupState.placeholder.proposerETAMinutes) min away"
            actionButton.configuration?.title = "Send Tile"
            actionButton.isHidden = false

        case .respond(let state, _):
            titleLabel.text = "Meet at \(state.placeName)?"
            subtitleLabel.text = state.placeAddress
            etaLabel.text = "They're \(state.proposerETAMinutes) min away"
            actionButton.configuration?.title = "Accept"
            actionButton.isHidden = false

        case .status(let state):
            titleLabel.text = state.placeName
            subtitleLabel.text = state.placeAddress
            switch state.status {
            case .proposed:
                etaLabel.text = "Waiting for them to accept…"
            case .accepted:
                etaLabel.text = "You're both headed there"
            }
            actionButton.isHidden = true
        }

        applyLayout(for: presentationStyle)
    }

    private func applyLayout(for presentationStyle: MSMessagesAppPresentationStyle) {
        switch presentationStyle {
        case .compact:
            detailStackView.isHidden = true
        case .expanded, .transcript:
            detailStackView.isHidden = false
        @unknown default:
            detailStackView.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func actionButtonTapped() {
        switch mode {
        case .compose:
            sendTile()
        case .respond(let state, let session):
            acceptTile(state, session: session)
        case .status:
            break
        }
    }

    private func sendTile() {
        // A brand new proposal starts a brand new session.
        insert(MeetupState.placeholder, session: nil)
    }

    private func acceptTile(_ state: MeetupState, session: MSSession?) {
        let accepted = MeetupState(
            id: state.id,
            placeName: state.placeName,
            placeAddress: state.placeAddress,
            latitude: state.latitude,
            longitude: state.longitude,
            proposerETAMinutes: state.proposerETAMinutes,
            accepterETAMinutes: 8, // placeholder until the container app's ETA engine runs
            status: .accepted
        )
        // Accepting reuses the proposer's session so both bubbles thread
        // together instead of appearing as a new message.
        insert(accepted, session: session)
    }

    private func insert(_ state: MeetupState, session: MSSession?) {
        guard let conversation = activeConversation else { return }

        let message = MSMessage(session: session ?? MSSession())
        let layout = MSMessageTemplateLayout()
        layout.image = tileImage
        layout.caption = state.placeName
        layout.subcaption = state.placeAddress
        layout.trailingCaption = state.status == .accepted
            ? "Both heading there"
            : "\(state.proposerETAMinutes) min"
        message.layout = layout
        message.url = state.encodedURL()
        message.summaryText = state.status == .accepted
            ? "Accepted meetup at \(state.placeName)"
            : "Proposed meetup at \(state.placeName)"

        conversation.insert(message) { [weak self] error in
            if let error {
                assertionFailure("Failed to insert message: \(error)")
            }
            DispatchQueue.main.async {
                self?.requestPresentationStyle(.compact)
            }
        }
    }

    /// Placeholder tile artwork until real map snapshots are wired up.
    private var tileImage: UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200))
        return renderer.image { _ in
            UIColor.systemBlue.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 200))

            let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 64, weight: .medium)
            guard let pin = UIImage(systemName: "mappin.and.ellipse", withConfiguration: symbolConfiguration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            else { return }
            pin.draw(at: CGPoint(x: (300 - pin.size.width) / 2, y: (200 - pin.size.height) / 2))
        }
    }
}
