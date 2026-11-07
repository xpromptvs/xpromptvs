import Foundation

/// Experimental v1: one same-frame color/alpha/hit surface. Logical and coded geometry differ.
public struct WorkspaceFormat: Codable, Equatable, Sendable {
    public let format:String
    public let logicalWidth:Int
    public let logicalHeight:Int
    public let capturedWidth:Int
    public let capturedHeight:Int
    public let codedWidth:Int
    public let codedHeight:Int
    public let codec:String
    public static let v1=WorkspaceFormat(format:"workspace-rgb-alpha-hit-v1",logicalWidth:1280,logicalHeight:800,capturedWidth:1280,capturedHeight:800,codedWidth:3840,codedHeight:800,codec:"av1")
    public var supported:Bool {self == Self.v1}
}
public struct WorkspaceApp: Codable, Equatable, Sendable {
    public let id:String
    public let name:String
    public let bundleID:String?
    public let processID:Int32?
    public init(id:String,name:String,bundleID:String?=nil,processID:Int32?=nil){self.id=id;self.name=name;self.bundleID=bundleID;self.processID=processID}
}
public struct WorkspaceMember: Codable, Equatable, Sendable {
    public let app:WorkspaceApp
    public let phase:String
    public let error:String?
    public init(app:WorkspaceApp,phase:String,error:String?=nil){self.app=app;self.phase=phase;self.error=error}
}
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var applications:[WorkspaceApp]=[]
    public var members:[WorkspaceMember]=[]
    public var source:String?=nil
    public var format:WorkspaceFormat=WorkspaceFormat.v1
    public var availability:String="disabled"
    public var error:String?=nil
    public var recoveryCount:Int=0
    public init(){}
    public func wire()->Data {
        guard let encoded=try? JSONEncoder().encode(self),var object=(try? JSONSerialization.jsonObject(with:encoded)) as? [String:Any] else{return Data()}
        object["t"]="apps-state"
        return (try? JSONSerialization.data(withJSONObject:object)) ?? Data()
    }
}
