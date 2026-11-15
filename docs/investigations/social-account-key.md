# Social data and the Hardcover account key

Connecting a different Hardcover account can't make the Apple TV save the new reader's profile under the previous account. The review of pull request 86 suspected that order; this investigation, on 2026-11-15, ruled it out and changed no code. Two narrower orders depend on timing instead of structure and are recorded under [What only timing rules out](#what-only-timing-rules-out).

See [Hardcover authentication](../HARDCOVER_AUTHENTICATION.md) for the login and its renewal, and [social views](../SOCIAL_VIEWS_AND_AMBIENT.md) for what social sync downloads.

## What was suspected

`SocialLibraryModel.load(token:account:…)` keys an account's saved profile (`socialOwner.<fingerprint>` in user defaults) and its reset between accounts on a hash of `account`, and it falls back to a hash of the token only when `account` is `nil`. `ShelfView.loadSocial` passes `LibraryModel.hardcoverTokenForSync()` as the token and `LibraryModel.hardcoverAccountID` as the account.

The suspicion: after a reader connects another account, the load that `connectionRevision` or `hardcoverConnected` starts could read the new token while `hardcoverAccountID` still names the previous account. That load would skip the reset between accounts, show the previous account's saved profile, and save the new reader's profile under the previous account's key. A wrong entry would last: later loads read the profile from that key and never ask Hardcover for it again.

## Why it can't happen

A token and an account ID that disagree would have to be readable between two main-actor turns. They aren't:

- **The connect path saves the token and records the account in one turn.** `LibraryModel.connectValidatedToken` validates the token and downloads the library first. Then, with no suspension between them, it saves the credential, sets `hardcoverConnected`, raises `connectionRevision`, and calls `install`, which records the account ID in its first statements, before its first suspension. `LibraryModel` is isolated to the main actor, so calling its own `install` doesn't leave the actor. A SwiftUI task that those changes start runs in a later turn, after the account ID is recorded.
- **The path that keeps a fresh library changes no account.** `connectValidatedToken` skips the download only when the validated account is already the active one.
- **The first connection uses the same code.** A reader without a saved login, with or without a library chosen from iCloud, connects through `connectValidatedToken`. Before that, `hardcoverTokenForSync()` returns no token, and a load without a token saves nothing.
- **A refresh doesn't change the token's account.** `refresh` records the account that Hardcover returns for the saved token. When no account ID is recorded yet, as for a login from a build that didn't save one, social sync keys on the token until the refresh records the ID, then starts over under the account's key. The two keys belong to the same account.
- **A different account needs a new login.** The app offers the sign-in card only without a saved login or after Hardcover rejects it (`needsHardcoverLink`), so a token changes accounts only through the connect path.
- **`ShelfView.loadSocial` reads the account after the token.** Swift evaluates the arguments in order, and only the token read can suspend, so the account ID is never older than the token.

## How it was checked

Two throwaway tests ran in `LibraryWorkflowTests` on a slim tvOS simulator and weren't committed:

1. A `LibraryModel` signed in to one account connected a token for another account. An observer of `connectionRevision` started a main-actor task at the change, as SwiftUI's `.task(id:)` does at the earliest. The task read the new account ID in its first statement, and the new token with the new account ID after `hardcoverTokenForSync()`.
2. The second test is described under the renewal order below.

## What only timing rules out

Neither order below was reproduced with the app's own call order. Both need `SocialLibraryModel` to keep working for an account after `LibraryModel` moved to another one.

### A renewal that finishes after the login was replaced

`HardcoverSession.renew(rejected:)` returns the saved access token when it differs from the rejected one, because another sync usually renewed it. After a new login replaced the old one, the saved token belongs to the new account. A social load for the previous account that is still waiting for Hardcover's rejection would continue with the new account's token, under the previous account's key. If that load has no saved profile yet, it asks Hardcover who the token belongs to and saves the new reader under the previous account's key.

What prevents it: `ShelfView` starts a load for the new account as soon as `connectionRevision` changes, and that load cancels the earlier one. A cancelled or replaced load saves nothing (`isCurrent(_:)`). The earlier load would need Hardcover's rejection, the renewal, and a second reply from Hardcover to all arrive before SwiftUI starts that task, which takes one update of the view.

The second throwaway test confirmed both halves with a `LibraryModel`, a `SocialLibraryModel`, and a held request. Without the load for the new account, the new reader's profile was saved under the previous account's key. With it, as `ShelfView` does, only the new account's key was written.

### A token read that outlasts a reconnection

`hardcoverTokenForSync()` suspends while a due token renews, and returns the token it started with when the renewal fails. If a reader disconnected and connected another account during that one renewal request, `loadSocial` would pair the previous account's token with the new account's ID. The request would have to stay open through a disconnect, a new link code, its approval, and a library download, then fail, and Hardcover would have to still accept the access token of the login that the disconnect revoked.

## If either becomes reachable

A change that adds a suspension between saving the credential and `install` in `connectValidatedToken`, or that moves the social load away from `ShelfView`'s `connectionRevision` task, reopens these orders. The fix belongs at the source: have `LibraryModel` hand social sync one value for a login (the token, its account ID, and a renewal that fails as cancelled once `HardcoverSession` saves or removes a login), not three values read at different times.
