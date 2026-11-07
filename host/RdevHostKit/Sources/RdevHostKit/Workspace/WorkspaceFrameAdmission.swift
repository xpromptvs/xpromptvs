// Pure state used by the workspace compositor. Callers serialize access.
import Foundation
import Darwin
import CoreVideo


struct CompositionFrameStore<Frame> {
    private struct Slot {
        let generation:UUID
        var timestamp:Int64?
        var frame:Frame?
    }
    private var slots:[UInt32:Slot]=[:]
    mutating func begin(_ id:UInt32)->UUID {
        let generation=UUID()
        slots[id]=Slot(generation:generation)
        return generation
    }
    mutating func retire(_ id:UInt32){slots.removeValue(forKey:id)}
    mutating func retire(_ id:UInt32,generation:UUID)->Bool {
        guard slots[id]?.generation==generation else{return false}
        slots.removeValue(forKey:id);return true
    }
    mutating func discard(_ id:UInt32,generation:UUID,before timestamp:Int64)->Bool {
        guard var slot=slots[id],slot.generation==generation else{return false}
        guard slot.timestamp.map({ $0 < timestamp }) ?? true else { return false }
        slot.frame=nil;slot.timestamp=timestamp;slots[id]=slot;return true
    }
    mutating func receive(_ frame:Frame,id:UInt32,generation:UUID,timestamp:Int64)->Bool {
        guard var slot=slots[id],slot.generation==generation,
              slot.timestamp.map({timestamp >= $0}) ?? true else{return false}
        slot.timestamp=timestamp;slot.frame=frame;slots[id]=slot;return true
    }
    var frames:[UInt32:Frame]{slots.compactMapValues(\.frame)}
}

struct CompositionSceneFence {
    private(set) var revision:UInt64=0
    mutating func invalidate(){revision &+= 1}
    func accepts(_ snapshot:UInt64)->Bool{revision==snapshot}
}

// Prototype resize admission; the caller samples native size before composing.
struct CompositionResizeAdmission<Frame> {
    private var accepted:[UInt32:Frame]=[:]
    mutating func select(id:UInt32,frame:Frame,captured:CGSize,current:CGSize?)->Frame? {
        guard let current,current.width.isFinite,current.height.isFinite,current.width>0,current.height>0 else{accepted.removeValue(forKey:id);return nil}
        if captured.width==current.width && captured.height==current.height {accepted[id]=frame}
        return accepted[id]
    }
    mutating func retain(_ ids:Set<UInt32>){accepted=accepted.filter{ids.contains($0.key)}}
    mutating func retire(_ id:UInt32){accepted.removeValue(forKey:id)}
}

// Single-owner mailbox: one in-flight frame and at most one latest waiting frame.
struct LatestValidationMailbox<Frame> {
    private(set) var active=false
    private var waiting:Frame?
    mutating func submit(_ frame:Frame)->Frame? {
        if active {waiting=frame;return nil}
        active=true;return frame
    }
    mutating func complete()->Frame? {
        if let next=waiting {waiting=nil;return next}
        active=false;return nil
    }
    mutating func cancel(){waiting=nil;active=false}
}

// A pending/rejected validation may retain its prior frame only until this lease expires.
struct ResizeRejectionLease {
    let timeout:Double
    private(set) var expired=false
    private(set) var pendingSince:Double?
    private var reported=false
    private mutating func update(now:Double){if let since=pendingSince,now-since>=timeout {expired=true}}
    mutating func observe(accepted:Bool,now:Double)->Bool {
        update(now:now)
        guard !expired else{return false}
        if accepted {pendingSince=nil;return true}
        if pendingSince==nil {pendingSince=now}
        return false
    }
    mutating func takeExpiry(now:Double)->Bool {
        update(now:now)
        guard expired,!reported else{return false}
        reported=true;return true
    }
}

