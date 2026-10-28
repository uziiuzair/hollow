/// The N largest stored files, kept in a fixed-size min-heap.
public struct TopFiles: Sendable {
    public let capacity: Int
    private var heap: [(file: FileIndex, allocated: UInt64)] = []

    public init(capacity: Int = 1000) {
        self.capacity = capacity
        heap.reserveCapacity(capacity)
    }

    public mutating func offer(_ file: FileIndex, allocated: UInt64) {
        if heap.count < capacity {
            heap.append((file, allocated))
            siftUp(heap.count - 1)
        } else if let smallest = heap.first, allocated > smallest.allocated {
            heap[0] = (file, allocated)
            siftDown(0)
        }
    }

    public func sortedDescending() -> [(FileIndex, UInt64)] {
        heap.sorted { $0.allocated > $1.allocated }.map { ($0.file, $0.allocated) }
    }

    private mutating func siftUp(_ i: Int) {
        var child = i
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].allocated < heap[parent].allocated else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ i: Int) {
        var parent = i
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            if left < heap.count, heap[left].allocated < heap[smallest].allocated { smallest = left }
            if right < heap.count, heap[right].allocated < heap[smallest].allocated { smallest = right }
            guard smallest != parent else { return }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
