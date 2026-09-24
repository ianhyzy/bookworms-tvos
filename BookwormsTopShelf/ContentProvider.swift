import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(
        completionHandler: @escaping ((any TVTopShelfContent)?) -> Void
    ) {
        completionHandler(TopShelfSnapshot.content(for: TopShelfSnapshot.read()))
    }
}
