//
//  LinkedList.swift
//  ErlangActorSystem
//
//  Created by Carson Katri on 6/26/25.
//

/// A doubly-linked list that has efficient `append` and `remove`.
final class LinkedList<Element>: Sequence {
    private var _head: UnsafeMutablePointer<Node>?
    private var _tail: UnsafeMutablePointer<Node>?
    
    deinit {
        var current = _tail
        while let node = current {
            current = node.pointee.previous
            node.deinitialize(count: 1)
            node.deallocate()
        }
    }
    
    struct Node {
        let value: Element
        fileprivate var next: UnsafeMutablePointer<Node>?
        fileprivate var previous: UnsafeMutablePointer<Node>?
        
        fileprivate init(value: Element, next: UnsafeMutablePointer<Node>? = nil, previous: UnsafeMutablePointer<Node>? = nil) {
            self.value = value
            self.next = next
            self.previous = previous
        }
    }
    
    /// Adds an element to the tail of the list.
    func append(_ value: Element) {
        let node = UnsafeMutablePointer<Node>.allocate(capacity: 1)
        node.initialize(to: Node(value: value, previous: _tail))
        if _head == nil {
            _head = node
        } else {
            _tail?.pointee.next = node
        }
        _tail = node
    }
    
    /// Deallocates the provided node and adjusts the pointers for its previous and next node.
    func remove(_ node: consuming Node) {
        if let previous = node.previous {
            previous.pointee.next = node.next
        } else {
            _head = node.next
        }
        
        if let next = node.next {
            let pointer = next.pointee.previous
            next.pointee.previous = node.previous
            pointer?.deinitialize(count: 1)
            pointer?.deallocate()
        } else {
            let pointer = _tail
            _tail = node.previous
            pointer?.deinitialize(count: 1)
            pointer?.deallocate()
        }
    }
    
    func makeIterator() -> Iterator {
        Iterator(current: _head)
    }
    
    struct Iterator: IteratorProtocol {
        private var current: UnsafeMutablePointer<Node>?
        
        fileprivate init(current: UnsafeMutablePointer<Node>?) {
            self.current = current
        }
        
        mutating func next() -> Node? {
            defer { current = current?.pointee.next }
            return current?.pointee
        }
    }
}
