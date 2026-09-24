import CloudKit
import Foundation

/// Maps system failures to recovery steps without exposing server payloads or local file paths.
enum UserFacingError {
    static func message(_ error: Error) -> String {
        if let cloud = error as? CKError {
            switch cloud.code {
            case .notAuthenticated:
                return "Sign in to iCloud in Apple TV Settings, then sync again."
            case .quotaExceeded:
                return
                    "iCloud storage is full. Free some space or increase your storage plan, then sync again."
            case .networkUnavailable, .networkFailure:
                return
                    "iCloud could not be reached. Check your internet connection, then sync again."
            case .requestRateLimited, .serviceUnavailable, .zoneBusy:
                return "iCloud is temporarily unavailable. Try syncing again later."
            case .permissionFailure:
                return
                    "iCloud denied access to this app's storage. Check your iCloud account and try again."
            default:
                return "iCloud could not complete the request. Try again later."
            }
        }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return
                    "The network connection is unavailable. Check Apple TV's connection and try again."
            case .timedOut:
                return
                    "The server did not respond in time. Check that it is reachable; private servers may require Tailscale."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return
                    "The server could not be reached. Check its address and your network connection."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return
                    "A secure connection could not be established. Check the server's HTTPS certificate and Apple TV's date and time."
            case .cannotDecodeContentData:
                return "The downloaded image or response could not be read. Try again later."
            case .cancelled:
                return "The request was cancelled."
            default:
                return "The connection failed. Check your network and try again."
            }
        }
        if error is DecodingError {
            return
                "The service returned data this app could not read. Try again later; an app update may be needed."
        }
        if let cocoa = error as? CocoaError {
            if cocoa.code == .fileWriteOutOfSpace {
                return "Apple TV storage is full. Free some space and try again."
            }
            return "Local data could not be read or saved. Try again after restarting the app."
        }
        if error is SourceError || error is HardcoverError || error is AIError
            || error is CloudStorageError || error is CredentialStore.CredentialError
            || error is AIStyleStore.SaveError
        {
            return error.localizedDescription
        }
        if error is CancellationError { return "The request was cancelled." }
        return "The operation could not be completed. Try again later."
    }
}
