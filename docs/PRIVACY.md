# Privacy implementation

The app and Top Shelf extension each include a `PrivacyInfo.xcprivacy` resource. Both declare no tracking and no tracking domains.

## Required-reason APIs

| Target | API category | Reason | Use |
| --- | --- | --- | --- |
| App | User defaults | `CA92.1` | Store and read this app's settings, sync schedules, and saved designs. |
| App | File timestamps | `C617.1` | Read modification dates of files in the app's cache for font-catalog freshness and image eviction. |
| Top Shelf | None | None | Read a JSON snapshot in the App Group container and publish public cover URLs. The app writes swept copies of current-read covers to the same container and removes posters no book uses. |

The extension does not call `UserDefaults` or read file timestamps. Do not copy the app's declarations into it without corresponding API use. Update these manifests whenever a target starts using another required-reason API. Reason definitions come from [Apple's API category reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

## Data flows

| Destination | Data sent | Purpose |
| --- | --- | --- |
| Hardcover | An OAuth access token, or a saved personal access token, in the authorization header; the device code and refresh token to the OAuth token endpoint, and the refresh token to the revocation endpoint; fixed read queries, book IDs, and selected reader IDs | Fetch account, library, edition, followed-reader, block-list, activity, rating, and review data. |
| Configured CWA server | Local username/password through HTTPS Basic authentication; catalog and cover requests | Fetch owned books and protected covers. Hidden in Settings while `BookPresentation.offersCWA` is false. |
| AI providers | No requests while generation is disabled | Retained implementation only; saved keys and designs remain stored. |
| Google Fonts and font hosting | Font family names from companion designs and series looks, requested during Book Wall preparation | Download the faces that Book Wall companion designs and series looks name, or their upright stand-ins. The retained AI spine path makes no requests while generated spines are disabled. |
| Artwork hosts | Cover and avatar URL requests, including covers chosen in the iPhone companion | Display and analyze cover artwork. |
| Private CloudKit database | Source snapshots, which include your own Hardcover reviews, saved legacy designs, a Hardcover account worklist, companion-generated spine designs, companion cover choices, series links and series looks that the Apple TV or a companion saves, only when the user turns on iCloud storage (off by default) | Restore the library, share it with your other Apple devices, and exchange design work with the iPhone and Mac companions. |

Network recipients can observe connection metadata such as an IP address. The app has no advertising or analytics SDK. The local request ledger does not upload diagnostics. Cloud archives and spine records exclude credentials but include the Hardcover account ID, book IDs, and reading metadata, including your own reviews. Spine records contain colors, typography choices, and hashes, not cover image bytes. Disabling or disconnecting Hardcover schedules deletion of the local companion design cache. Turning off iCloud does not delete cloud records.

## Collection disclosures

The manifests declare required-reason API use; they do not yet declare collected-data categories. This is not a claim that no data leaves the device. The developer receives no user data, so **Data Not Collected** is the expected App Store privacy answer for the current build; confirm it against Apple's definitions when answering. Keep the manifest, the [published privacy policy](https://ian.gay/bookworms-privacy-policy/), the [Apple TV privacy policy text](RELEASING.md#apple-tv-privacy-policy-text), and App Store privacy answers consistent.

Apple distinguishes real-time request processing from retained collection. Generation is currently disabled. Reassess disclosure before enabling any automatic provider requests. See [Apple's privacy questionnaire guidance](https://developer.apple.com/app-store/app-privacy-details/).

## Local verification

Regenerate the project with `xcodegen generate`, then archive the Release scheme. Run:

```sh
python3 scripts/verify-release-archive.py PATH_TO_ARCHIVE
```

The script checks embedded manifests, signature validity, entitlements, versions, deployment target, assets, and extension packaging. It does not contact App Store Connect or validate provider retention policies.

Social snapshots contain reader profiles, activities, ratings, and reviews in the local cache only. They are not included in the private CloudKit archive; only your own reviews travel there, in the library snapshot. Ambient playback uses saved metadata and does not initiate source sync or AI generation.
