import Foundation
import Speech

/// Cancellation-only handle around Apple's concrete recognition task.
///
/// Keeping the handle small gives the on-device policy seam a deterministic test double
/// without pretending that `SFSpeechRecognitionTask` itself can be constructed in tests.
final class AppleSpeechTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        self.cancellation = cancel
    }

    func cancel() {
        let action: (() -> Void)? = lock.withLock {
            defer { cancellation = nil }
            return cancellation
        }
        action?()
    }
}

/// The single boundary through which DevType may start legacy Apple Speech.
///
/// `SFSpeechRecognizer` can require Apple's network service for a locale. Both the batch
/// adapter and optional live preview declare an on-device-only route, so they must inspect
/// `supportsOnDeviceRecognition` and set `requiresOnDeviceRecognition` before this boundary
/// is invoked. Tests inject a runtime whose start closure records any policy violation.
final class AppleOnDeviceSpeechRuntime: @unchecked Sendable {
    typealias ResultHandler = (SFSpeechRecognitionResult?, Error?) -> Void
    typealias StartRecognition = (
        SFSpeechRecognitionRequest,
        @escaping ResultHandler
    ) -> AppleSpeechTaskHandle

    private let availability: () -> Bool
    private let onDeviceSupport: () -> Bool
    private let startRecognition: StartRecognition

    init(
        isAvailable: @escaping () -> Bool,
        supportsOnDeviceRecognition: @escaping () -> Bool,
        startRecognition: @escaping StartRecognition
    ) {
        self.availability = isAvailable
        self.onDeviceSupport = supportsOnDeviceRecognition
        self.startRecognition = startRecognition
    }

    var isAvailable: Bool { availability() }
    var supportsOnDeviceRecognition: Bool { onDeviceSupport() }

    func startOnDeviceRecognition(
        with request: SFSpeechRecognitionRequest,
        resultHandler: @escaping ResultHandler
    ) -> AppleSpeechTaskHandle? {
        guard supportsOnDeviceRecognition, request.requiresOnDeviceRecognition else {
            return nil
        }
        return startRecognition(request, resultHandler)
    }

    static func system(locale: Locale, includeEnglishFallback: Bool) -> AppleOnDeviceSpeechRuntime? {
        let recognizer = SFSpeechRecognizer(locale: locale)
            ?? (includeEnglishFallback ? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) : nil)
            ?? SFSpeechRecognizer()
        guard let recognizer else { return nil }

        return AppleOnDeviceSpeechRuntime(
            isAvailable: { recognizer.isAvailable },
            supportsOnDeviceRecognition: { recognizer.supportsOnDeviceRecognition },
            startRecognition: { request, resultHandler in
                let task = recognizer.recognitionTask(with: request, resultHandler: resultHandler)
                return AppleSpeechTaskHandle(cancel: { task.cancel() })
            }
        )
    }
}
