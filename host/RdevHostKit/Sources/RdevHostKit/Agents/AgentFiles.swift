import Foundation
import ImageIO

/// Access is scoped to an attachment upload or an image path actually reported in that thread.
/// Owned by the manager's serial queue; no browser-supplied path becomes an unrestricted file read.
final class AgentFiles {
    private struct Upload { let url: URL; let thread: String; let image: Bool; var seq = 0; var size = 0; var complete = false }
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("xpromptvs-agents-" + UUID().uuidString)
    private var uploads: [String:Upload] = [:]
    private var images: [String:Set<String>] = [:]
    private var used = Set<String>()
    private var inlineImages:[String:(url:URL,size:Int,thread:String,item:String)]=[:]
    private var inlineOrder=[String]()
    private func inlineKey(_ thread:String,_ turn:String,_ item:String,_ index:Int)->String { [thread,turn,item,String(index)].map{String($0.utf8.count)+":"+$0}.joined() }
    func inlinePath(thread:String,turn:String,item:String,index:Int)->String? {
        let key=inlineKey(thread,turn,item,index)
        guard let cached=inlineImages[key],FileManager.default.fileExists(atPath:cached.url.path) else{return nil}
        inlineOrder.removeAll{$0==key};inlineOrder.append(key);return cached.url.path
    }
    func prepareInline(thread:String,turn:String,item:String,index:Int,response:[String:Any]) throws -> String {
        guard let row=(response["data"] as? [[String:Any]])?.first(where:{($0["turnId"] as? String)==turn&&($0["item"] as? [String:Any])?["id"] as? String == item}) else{throw CodexError.message("Sent image has not been persisted yet")}
        guard let record=row["item"] as? [String:Any],record["type"] as? String == "userMessage",
              let inputs=record["content"] as? [[String:Any]],inputs.indices.contains(index),inputs[index]["type"] as? String == "image",
              let url=inputs[index]["url"] as? String,url.utf8.count<=45*1024*1024,
              let comma=url.firstIndex(of:",") else{throw CodexError.message("Sent image is unavailable")}
        let types=["data:image/png;base64":"png","data:image/jpeg;base64":"jpg","data:image/webp;base64":"webp","data:image/gif;base64":"gif"]
        guard let ext=types[String(url[..<comma])],let data=Data(base64Encoded:String(url[url.index(after:comma)...])),data.count<=32*1024*1024 else{throw CodexError.message("Unsupported sent image")}
        if let cached=inlinePath(thread:thread,turn:turn,item:item,index:index){return cached}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=root.appendingPathComponent("input-"+UUID().uuidString+"."+ext)
        guard FileManager.default.createFile(atPath:file.path,contents:data,attributes:[.posixPermissions:0o600]) else{throw CodexError.message("Cannot cache sent image")}
        let key=inlineKey(thread,turn,item,index)
        inlineImages[key]=(file,data.count,thread,item);inlineOrder.append(key);images[thread+":"+item,default:[]].insert(file.path)
        while inlineImages.count>64||inlineImages.values.reduce(0,{$0+$1.size})>64*1024*1024 {
            let old=inlineOrder.removeFirst();if let cached=inlineImages.removeValue(forKey:old){
                try? FileManager.default.removeItem(at:cached.url)
                let reference=cached.thread+":"+cached.item;images[reference]?.remove(cached.url.path)
                if images[reference]?.isEmpty == true{images.removeValue(forKey:reference)}
            }
        }
        return file.path
    }
    func prepareClaudeInline(thread:String,turn:String,item:String,index:Int,response:[String:Any]) throws -> String {
        guard let message=(response["data"] as? [[String:Any]])?.first(where:{$0["uuid"] as? String == item&&$0["type"] as? String == "user"}),
              let content=(message["message"] as? [String:Any])?["content"] as? [[String:Any]] else{throw CodexError.message("Sent image is unavailable")}
        let inputs=content.filter{$0["type"] as? String != "tool_result"}.map { input -> [String:Any] in
            guard input["type"] as? String == "image",let source=input["source"] as? [String:Any],source["type"] as? String == "base64",
                  let mime=source["media_type"] as? String,let data=source["data"] as? String else{return input}
            return ["type":"image","url":"data:\(mime);base64,\(data)"]
        }
        return try prepareInline(thread:thread,turn:turn,item:item,index:index,response:["data":[["turnId":turn,"item":["id":item,"type":"userMessage","content":inputs]]]])
    }
    func close(preserveUsed: Bool = false) {
        for cached in inlineImages.values{try? FileManager.default.removeItem(at:cached.url)}
        inlineImages.removeAll();inlineOrder.removeAll()
        if preserveUsed && !used.isEmpty {
            for (id,upload) in uploads where !used.contains(id) { try? FileManager.default.removeItem(at:upload.url) }
        } else { try? FileManager.default.removeItem(at:root) }
        uploads.removeAll(); images.removeAll(); if !preserveUsed {used.removeAll()}
    }
    func upload(thread: String, args: [String:Any]) throws -> [String:Any] {
        guard let id = args["upload"] as? String, UUID(uuidString:id) != nil, let seq = args["seq"] as? Int,
              let encoded = args["data"] as? String, let bytes = Data(base64Encoded:encoded), bytes.count <= 16384 else { throw CodexError.message("Invalid attachment chunk") }
        if uploads[id] == nil {
            guard seq == 0, uploads.count < 32, let name = args["name"] as? String, !name.isEmpty else { throw CodexError.message("Attachment limit reached") }
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let safeName = String(URL(fileURLWithPath:name).lastPathComponent.prefix(128))
            let url = root.appendingPathComponent(id+"-"+safeName)
            guard FileManager.default.createFile(atPath:url.path,contents:Data(),attributes:[.posixPermissions:0o600]) else { throw CodexError.message("Cannot create attachment") }
            uploads[id] = Upload(url:url,thread:thread,image:args["image"] as? Bool == true)
        }
        guard var upload = uploads[id], upload.thread == thread, upload.seq == seq, !upload.complete,
              upload.size + bytes.count <= 32*1024*1024,
              uploads.values.reduce(0,{$0+$1.size}) + bytes.count <= 64*1024*1024 else { throw CodexError.message("Attachment is out of order, already complete, or exceeds the limit") }
        let handle = try FileHandle(forWritingTo:upload.url); defer {try? handle.close()}
        try handle.seekToEnd(); try handle.write(contentsOf:bytes)
        upload.seq += 1; upload.size += bytes.count; upload.complete = args["last"] as? Bool == true; uploads[id] = upload
        return ["upload":id,"complete":upload.complete]
    }
    func inputs(thread: String, ids: [String]) throws -> [[String:Any]] {
        guard ids.count <= 16 else { throw CodexError.message("Too many attachments") }
        return try ids.map { id in
            guard let upload = uploads[id], upload.thread == thread, upload.complete else { throw CodexError.message("Attachment is not ready for this session") }
            used.insert(id)
            return upload.image ? ["type":"localImage","path":upload.url.path] : ["type":"mention","name":upload.url.lastPathComponent,"path":upload.url.path]
        }
    }
    func remember(_ object: Any, thread: String) {
        func walk(_ value: Any, depth: Int) {
            guard depth < 12 else { return }
            if let array = value as? [Any] { for child in array.prefix(2000) { walk(child,depth:depth+1) }; return }
            guard let row = value as? [String:Any] else { return }
            if let id = row["id"] as? String, ["imageView","imageGeneration","userMessage"].contains(row["type"] as? String ?? "") {
                var paths = Set<String>()
                if let path = row["path"] as? String, path.hasPrefix("/") { paths.insert(path) }
                if let path = row["savedPath"] as? String, path.hasPrefix("/") { paths.insert(path) }
                for input in row["content"] as? [[String:Any]] ?? [] {
                    if input["type"] as? String == "localImage", let path = input["path"] as? String { paths.insert(path) }
                }
                if !paths.isEmpty, images.count < 2000 { images[thread+":"+id,default:[]].formUnion(paths) }
            }
            for (key,child) in row where ["thread","turns","items","data","item","turn"].contains(key) { walk(child,depth:depth+1) }
        }
        walk(object,depth:0)
    }
    private func imageURL(thread: String, item: String, path: String) throws -> URL {
        guard images[thread+":"+item]?.contains(path) == true else { throw CodexError.message("This image path was not reported by this session") }
        let url = URL(fileURLWithPath:path), attrs = try FileManager.default.attributesOfItem(atPath:path)
        guard attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? NSNumber, size.intValue <= 32*1024*1024 else { throw CodexError.message("Image is unavailable or larger than 32 MiB") }
        return url
    }
    /// Dimensions and an optional bounded thumbnail hash; original pixels stay off this reply.
    func info(thread: String, item: String, path: String) throws -> [String:Any] {
        let url=try imageURL(thread:thread,item:item,path:path)
        let types=["public.png":"image/png","public.jpeg":"image/jpeg","com.compuserve.gif":"image/gif","org.webmproject.webp":"image/webp","public.heic":"image/heic","public.heif":"image/heif"]
        guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let type=CGImageSourceGetType(source) as String?,let mime=types[type],
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary) as? [CFString:Any],
              let w=properties[kCGImagePropertyPixelWidth] as? NSNumber,let h=properties[kCGImagePropertyPixelHeight] as? NSNumber,
              w.intValue>0,h.intValue>0,w.intValue<=100_000,h.intValue<=100_000 else {throw CodexError.message("Image dimensions are unavailable")}
        let orientation=(properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapped=(5...8).contains(orientation)
        var result:[String:Any]=["name":url.lastPathComponent,"mime":mime,"width":swapped ? h.intValue:w.intValue,"height":swapped ? w.intValue:h.intValue]
        // Some decoders materialize the source despite the thumbnail request. Bound that work too.
        if w.intValue*h.intValue<=16_000_000,let hash=AgentBlurHash.thumbnail(source){result["blurhash"]=hash}
        return result
    }
    func asset(thread: String, item: String, path: String) throws -> [String:Any] {
        let url=try imageURL(thread:thread,item:item,path:path)
        let data = try Data(contentsOf:url)
        guard data.count <= 32*1024*1024 else { throw CodexError.message("Image changed size") }
        let types = ["png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","gif":"image/gif","webp":"image/webp","heic":"image/heic"]
        return ["name":url.lastPathComponent,"mime":types[url.pathExtension.lowercased()] ?? "application/octet-stream","data":data.base64EncodedString()]
    }
}
