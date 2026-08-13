import SwiftUI
import BideKit

/// MapKit-backed place search field used by compose forms.
public struct PlaceSearchField: View {

    @Bindable private var service: PlaceSearchService
    @Binding private var destination: Destination?

    private let placeholder: String

    @FocusState private var isFocused: Bool
    @State private var resolving: PlaceSuggestion?
    @State private var failed = false

    public init(
        service: PlaceSearchService,
        destination: Binding<Destination?>,
        placeholder: String = "Search locations"
    ) {
        self.service = service
        self._destination = destination
        self.placeholder = placeholder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field

            if destination == nil, !service.suggestions.isEmpty {
                suggestionList
            }

            if failed {
                Text("Couldn't look that place up. Try again.")
                    .font(BideFont.caption)
                    .foregroundStyle(BideColor.delay(.late))
            }
        }
        .animation(.easeOut(duration: 0.18), value: service.suggestions.count)
        .animation(.easeOut(duration: 0.18), value: destination)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(BideColor.secondaryText)

            if let destination {
                Text(destination.name)
                    .font(BideFont.prompt)
                    .foregroundStyle(BideColor.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(BideColor.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear destination")
            } else {
                TextField(
                    "",
                    text: $service.query,
                    prompt: Text(placeholder).foregroundColor(BideColor.secondaryText)
                )
                .font(BideFont.prompt)
                .foregroundStyle(BideColor.primaryText)
                .bideSearchInput()
                .focused($isFocused)

                if resolving != nil {
                    ProgressView().controlSize(.small).tint(BideColor.secondaryText)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: BideMetrics.controlHeight)
        .background(BideColor.control, in: Capsule())
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(service.suggestions.prefix(4)) { suggestion in
                Button {
                    select(suggestion)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title)
                            .font(BideFont.body)
                            .foregroundStyle(BideColor.primaryText)
                        if !suggestion.subtitle.isEmpty {
                            Text(suggestion.subtitle)
                                .font(BideFont.caption)
                                .foregroundStyle(BideColor.secondaryText)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if suggestion.id != service.suggestions.prefix(4).last?.id {
                    Divider().overlay(BideColor.border)
                }
            }
        }
        .background(
            BideColor.control,
            in: RoundedRectangle(cornerRadius: BideMetrics.controlRadius, style: .continuous)
        )
    }

    private func select(_ suggestion: PlaceSuggestion) {
        resolving = suggestion
        failed = false
        isFocused = false

        Task {
            defer { resolving = nil }
            do {
                destination = try await service.resolve(suggestion)
                service.clear()
            } catch {
                failed = true
            }
        }
    }

    private func clear() {
        destination = nil
        service.clear()
        failed = false
        isFocused = true
    }
}
