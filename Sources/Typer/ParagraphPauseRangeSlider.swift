import SwiftUI

/// Two thumbs on one track, with separate keyboard and VoiceOver adjustments.
struct ParagraphPauseRangeSlider: View {
    @Binding var minimum: Int
    @Binding var maximum: Int
    @State private var dragging: Thumb?
    @FocusState private var focused: Thumb?
    private enum Thumb: Hashable { case minimum, maximum }
    private let bounds = 1...30

    private var lower: Int { min(bounds.upperBound, max(bounds.lowerBound, min(minimum, maximum))) }
    private var upper: Int { min(bounds.upperBound, max(bounds.lowerBound, max(minimum, maximum))) }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Min \(lower) min")
                Spacer()
                Text("Max \(upper) min")
            }.font(.system(size: 10, weight: .medium, design: .monospaced))
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 24)
                let left = position(lower, width: width), right = position(upper, width: width)
                ZStack(alignment: .leading) {
                    Capsule().fill(TyperTheme.raised).frame(height: 4).padding(.horizontal, 12)
                    Capsule().fill(TyperTheme.primary).frame(width: max(2, right - left), height: 4).offset(x: left)
                    thumb(.minimum, value: lower).position(x: left, y: 16)
                    thumb(.maximum, value: upper).position(x: right, y: 16)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    if dragging == nil {
                        dragging = abs(value.startLocation.x - left) < abs(value.startLocation.x - right) ? .minimum : .maximum
                        // With a fixed wait the thumbs coincide. The first
                        // movement selects which end to open, in either direction.
                        if left == right { dragging = value.translation.width < 0 ? .minimum : .maximum }
                        focused = dragging
                    }
                    let selected = Int((Double((value.location.x - 12) / width) * 29 + 1).rounded())
                    set(dragging ?? .minimum, value: selected)
                }.onEnded { _ in dragging = nil })
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Paragraph pause range")
            }.frame(height: 32)
            HStack { Text("1 min"); Spacer(); Text("30 min") }
                .font(.system(size: 9)).foregroundStyle(TyperTheme.muted)
        }
    }

    private func position(_ value: Int, width: CGFloat) -> CGFloat { 12 + CGFloat(value - 1) / 29 * width }

    private func thumb(_ thumb: Thumb, value: Int) -> some View {
        Circle().fill(TyperTheme.ink).frame(width: 18, height: 18)
            .overlay { Circle().stroke(focused == thumb ? TyperTheme.primary : TyperTheme.muted, lineWidth: focused == thumb ? 3 : 1) }
            .frame(width: 28, height: 32)
            .focusable().focused($focused, equals: thumb)
            .onMoveCommand { direction in
                if direction == .left || direction == .down { set(thumb, value: value - 1) }
                if direction == .right || direction == .up { set(thumb, value: value + 1) }
            }
            .accessibilityElement()
            .accessibilityLabel(thumb == .minimum ? "Minimum paragraph pause" : "Maximum paragraph pause")
            .accessibilityValue("\(value) minutes")
            .accessibilityAdjustableAction { direction in
                set(thumb, value: value + (direction == .increment ? 1 : -1))
            }
    }

    private func set(_ thumb: Thumb, value: Int) {
        let value = min(bounds.upperBound, max(bounds.lowerBound, value))
        if thumb == .minimum { minimum = min(value, upper); maximum = upper }
        else { minimum = lower; maximum = max(value, lower) }
    }
}
