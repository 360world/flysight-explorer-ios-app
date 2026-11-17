//
//  ScrubOverlay.swift — horizontal scrubbing inside a scrollable list
//
//  SwiftUI gestures can't handle this: `gesture`, `simultaneousGesture`
//  and `LongPressGesture.sequenced` all capture the touch as soon as it lands,
//  and from then on the ScrollView won't scroll.
//
//  In UIKit, however, it can be solved precisely:
//    - `shouldRecognizeSimultaneouslyWith → true`, so the ScrollView's pan
//      gesture is NOT broken, while we still receive the events too,
//    - we decide the direction from the first meaningful movement: if vertical,
//      we cancel ourselves (isEnabled off/on) and the motion belongs purely to scrolling.
//
//  This way you can scrub horizontally on the chart and scroll up/down.
//

import SwiftUI
import UIKit

struct ScrubOverlay: UIViewRepresentable {
    /// The finger's horizontal position in the view's coordinates.
    var onScrub: (CGFloat) -> Void
    /// Called when a real scrub begins (e.g. to stop playback).
    var onBegan: () -> Void = {}
    /// Tap — the cursor is placed there immediately.
    var onTap: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        v.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        v.addGestureRecognizer(tap)

        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onScrub = onScrub
        context.coordinator.onBegan = onBegan
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrub: onScrub, onBegan: onBegan, onTap: onTap)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onScrub: (CGFloat) -> Void
        var onBegan: () -> Void
        var onTap: (CGFloat) -> Void

        /// Whether the current motion's direction has been decided yet.
        private var decided = false
        /// Vertical motion → handed over to scrolling.
        private var isVertical = false
        /// The ScrollView we disabled for the duration of the scrub.
        private weak var lockedScrollView: UIScrollView?

        init(onScrub: @escaping (CGFloat) -> Void,
             onBegan: @escaping () -> Void,
             onTap: @escaping (CGFloat) -> Void) {
            self.onScrub = onScrub
            self.onBegan = onBegan
            self.onTap = onTap
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            switch g.state {
            case .began:
                decided = false
                isVertical = false

            case .changed:
                if !decided {
                    let t = g.translation(in: view)
                    // Wait until the direction can be determined.
                    guard abs(t.x) + abs(t.y) > 6 else { return }
                    decided = true
                    isVertical = abs(t.y) > abs(t.x)
                    if isVertical {
                        // Cancel ourselves: toggling off/on aborts this
                        // recognition, and scrolling continues undisturbed.
                        g.isEnabled = false
                        g.isEnabled = true
                        return
                    }
                    // Horizontal motion: we LOCK scrolling until the motion
                    // ends, so the screen doesn't slide up/down while you're
                    // dragging the cursor. Only one thing should happen at a time.
                    lockScroll(around: view)
                    onBegan()
                }
                guard !isVertical else { return }
                onScrub(g.location(in: view).x)

            case .ended, .cancelled, .failed:
                decided = false
                isVertical = false
                unlockScroll()

            default:
                break
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view else { return }
            onTap(g.location(in: view).x)
        }

        /// Finds the enclosing ScrollView and disables it for the duration
        /// of the scrub. `isScrollEnabled = false` also stops any scrolling in
        /// progress immediately, so the screen stays where it was.
        private func lockScroll(around view: UIView) {
            var v: UIView? = view.superview
            while let cur = v {
                if let sv = cur as? UIScrollView {
                    if sv.isScrollEnabled {
                        sv.isScrollEnabled = false
                        lockedScrollView = sv
                    }
                    return
                }
                v = cur.superview
            }
        }

        private func unlockScroll() {
            lockedScrollView?.isScrollEnabled = true
            lockedScrollView = nil
        }

        /// THIS is the key: we don't exclude the ScrollView's pan gesture.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer)
        -> Bool { true }
    }
}
