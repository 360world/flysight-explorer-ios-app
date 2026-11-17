//
//  ScrubOverlay.swift — vízszintes csúszkáltatás görgethető listában
//
//  A SwiftUI gesztusai erre nem alkalmasak: a `gesture`, a `simultaneousGesture`
//  és a `LongPressGesture.sequenced` is lefogja az érintést már a lenyomásnál,
//  és onnantól a ScrollView nem görget.
//
//  UIKit-ben viszont pontosan megoldható:
//    - `shouldRecognizeSimultaneouslyWith → true`, tehát a ScrollView pan
//      gesztusa NEM sérül, ugyanakkor mi is megkapjuk az eseményeket,
//    - az első érdemi elmozdulásból eldöntjük az irányt: ha függőleges, magunkat
//      lemondjuk (isEnabled ki/be), és a mozdulat tisztán a görgetésé marad.
//
//  Így a charton vízszintesen csúszkálni lehet, fel/le pedig görgetni.
//

import SwiftUI
import UIKit

struct ScrubOverlay: UIViewRepresentable {
    /// Az ujj vízszintes pozíciója a nézet koordinátáiban.
    var onScrub: (CGFloat) -> Void
    /// Akkor hívjuk, amikor egy valódi csúszkáltatás elindul (pl. lejátszás stop).
    var onBegan: () -> Void = {}
    /// Koppintás — a kurzort azonnal odahelyezzük.
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

        /// Eldőlt-e már az aktuális mozdulat iránya.
        private var decided = false
        /// Függőleges mozdulat → a görgetésnek engedjük át.
        private var isVertical = false
        /// Amelyik ScrollView-t a csúszkáltatás idejére kikapcsoltuk.
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
                    // Megvárjuk, míg értelmezhető az irány.
                    guard abs(t.x) + abs(t.y) > 6 else { return }
                    decided = true
                    isVertical = abs(t.y) > abs(t.x)
                    if isVertical {
                        // Lemondjuk magunkat: a ki/bekapcsolás megszakítja ezt
                        // a felismerést, a görgetés zavartalanul folytatódik.
                        g.isEnabled = false
                        g.isEnabled = true
                        return
                    }
                    // Vízszintes mozdulat: a mozdulat végéig LEZÁRJUK a
                    // görgetést, hogy a kijelző ne csúszkáljon fel/le, amíg a
                    // kurzort húzod. Egyszerre csak egy dolog történjen.
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

        /// Megkeresi a befoglaló ScrollView-t, és a csúszkáltatás idejére
        /// kikapcsolja. A `isScrollEnabled = false` a folyamatban lévő görgetést
        /// is azonnal megszakítja, tehát a kijelző megáll ott, ahol volt.
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

        /// EZ a kulcs: nem zárjuk ki a ScrollView pan gesztusát.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer)
        -> Bool { true }
    }
}
