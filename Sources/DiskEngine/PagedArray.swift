/// An append-only array stored in fixed pages of 65,536 elements. Growing never
/// copies existing elements, so peak memory stays close to the live size.
public struct PagedArray<Element>: RandomAccessCollection, MutableCollection {
    static var pageSize: Int { 65_536 }

    private var pages: [ContiguousArray<Element>] = []
    public private(set) var count = 0

    public init() {}

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public mutating func append(_ element: Element) {
        if count % Self.pageSize == 0 {
            var page = ContiguousArray<Element>()
            page.reserveCapacity(Self.pageSize)
            pages.append(page)
        }
        pages[pages.count - 1].append(element)
        count += 1
    }

    public subscript(position: Int) -> Element {
        get { pages[position / Self.pageSize][position % Self.pageSize] }
        _modify { yield &pages[position / Self.pageSize][position % Self.pageSize] }
    }
}
