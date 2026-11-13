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
| Google Fonts and font hosting | The font catalog request, and font family names from companion designs and series looks, requested during Book Wall preparation | Download the faces that Book Wall companion designs and series looks name, or their upright stand-ins. The retained AI spine path makes no requests while generated spines are disabled. |
| Artwork hosts | Cover and avatar URL requests, including covers chosen in the iPhone companion | Display and analyze cover artwork. |
| Private CloudKit database | Source snapshots, which include your own Hardcover reviews, the Hardcover username, and each source's sync date; the Hardcover accounts that the reader merged; saved legacy designs; a Hardcover account worklist; companion-generated spine designs; companion cover choices; series links and series looks that the Apple TV or a companion saves; and, for **Merge**, copies of another account's designs, cover choices, series links, series looks, and Top Five pins. All of it only when the user turns on iCloud storage (off by default) | Restore the library, share it with your other Apple devices, and exchange design work with the iPhone and Mac companions. |

The example profile (`ExampleProfile/`) is the owner's own Hardcover reading, bundled in the app with his consent: books, ratings, finish dates, descriptions, series, and companion designs, looks, chosen covers, and series links, under the account ID `example`, without reviews or community ratings. The app only displays it, and sends nothing about it besides the cover and font requests that any library makes. This repository is public, so Git ignores the folder apart from its placeholder; `scripts/export-example-profile.py` writes it locally before an archive. Never commit it, print its contents, or use it in tests or published screenshots. Data in a shipped build can't be recalled; removing a book reaches only later builds.

Network recipients can observe connection metadata such as an IP address. The app has no advertising or analytics SDK. Release builds keep each source's latest sync error on the device (`LibraryModel.sourceErrors`), and it never goes to iCloud. Each source snapshot carries its sync date and, for Hardcover, the account's username (`SourceSnapshot.syncedAt` and `username`), on the device and in the iCloud archive. Cloud archives and spine records exclude credentials but include the Hardcover account ID, book IDs, and reading metadata, including your own reviews. Spine records contain colors, typography choices, and hashes, not cover image bytes. Disabling or disconnecting Hardcover schedules deletion of the local companion design cache. Turning off iCloud does not delete cloud records.

## Collection disclosures

The manifests declare required-reason API use; they do not yet declare collected-data categories. This is not a claim that no data leaves the device. The developer receives no user data, so **Data Not Collected** is the expected App Store privacy answer for the current build; confirm it against Apple's definitions when answering. Keep the manifest, the [published privacy policy](https://ian.gay/bookworms-privacy-policy/), the [privacy policy text](RELEASING.md#privacy-policy-text), and App Store privacy answers consistent. That policy also covers the iPhone and Mac app, whose repository documents its own data flows; the table above covers only the Apple TV app.

Apple distinguishes real-time request processing from retained collection. Generation is currently disabled. Reassess disclosure before enabling any automatic provider requests. See [Apple's privacy questionnaire guidance](https://developer.apple.com/app-store/app-privacy-details/).

## Local verification

Regenerate the project with `xcodegen generate`, then archive Release with the `BookwormsDevice` scheme. Run:

```sh
python3 scripts/verify-release-archive.py PATH_TO_ARCHIVE --expected-version X.Y.Z --expected-build N
```

The script checks embedded manifests, signature validity, entitlements, versions, deployment target, assets, and extension packaging. It does not contact App Store Connect or validate provider retention policies.

Social snapshots contain reader profiles, activities, ratings, and reviews in the local cache only. They are not included in the private CloudKit archive; only your own reviews travel there, in the library snapshot. Ambient playback uses saved metadata and does not initiate source sync or AI generation.
