import SwiftUI

#if BOOKWORMS_DIAGNOSTICS
    import UIKit

    /// Observes public focus notifications without changing focus decisions.
    struct PerformanceDiagnosticObserver: UIViewRepresentable {
        func makeUIView(context: Context) -> ObserverView { ObserverView() }
        func updateUIView(_ uiView: ObserverView, context: Context) {}

        final class ObserverView: UIView {
            private var installed = false
            private var pressObserver: PressObserver?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard PerformanceDiagnostics.enabled, let window, !installed else { return }
                installed = true
                let recognizer = PressObserver()
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.allowedPressTypes = [
                    UIPress.PressType.upArrow.rawValue, UIPress.PressType.downArrow.rawValue,
                    UIPress.PressType.leftArrow.rawValue, UIPress.PressType.rightArrow.rawValue,
                    UIPress.PressType.select.rawValue, UIPress.PressType.menu.rawValue,
                ]
                .map { NSNumber(value: $0) }
                window.addGestureRecognizer(recognizer)
                pressObserver = recognizer
                NotificationCenter.default.addObserver(
                    self, selector: #selector(focusChanged(_:)),
                    name: UIFocusSystem.didUpdateNotification, object: nil)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(focusFailed(_:)),
                    name: UIFocusSystem.movementDidFailNotification, object: nil)
                PerformanceDiagnostics.event(
                    "ObserverReady", Int(window.screen.maximumFramesPerSecond))
            }

            @objc private func focusChanged(_ notification: Notification) {
                PerformanceDiagnostics.event("NativeFocusChanged")
            }

            @objc private func focusFailed(_ notification: Notification) {
                PerformanceDiagnostics.event("NativeFocusFailed")
            }

            deinit { NotificationCenter.default.removeObserver(self) }
        }

        final class PressObserver: UIGestureRecognizer {
            override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
                for press in presses {
                    PerformanceDiagnostics.event("DeliveredPress", press.type.rawValue)
                }
                // Fail immediately so the observer never recognizes or consumes a remote command.
                state = .failed
            }
        }
    }
#endif

extension View {
    @ViewBuilder func performanceGlassButton() -> some View {
        #if BOOKWORMS_DIAGNOSTICS
            if PerformanceDiagnostics.isolates("glass") {
                self.buttonStyle(.bordered)
            } else {
                self.buttonStyle(.glass)
            }
        #else
            self.buttonStyle(.glass)
        #endif
    }
}
