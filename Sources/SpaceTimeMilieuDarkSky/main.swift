import Foundation
import SpaceTimeMilieuModel
import Kitura
import Dispatch
import LoggerAPI
import HeliumLogger

private let Default_APIKey="Get one from https://darksky.net/dev/register"

#if os(Linux)
    import Glibc
#endif

let ourLogger = HeliumLogger(.info)
ourLogger.dateFormat = "YYYY/MM/dd-HH:mm:ss.SSS"
ourLogger.format = "(%type): (%date) - (%msg)"
ourLogger.details = false
Log.logger = ourLogger

let myCertPath = "./cert.pem"
let myKeyPath = "./key.pem"
let myChainPath = "./chain.pem"

//Enable Core Dumps on Linux
#if os(Linux)
    
let unlimited = rlimit.init(rlim_cur: rlim_t(INT32_MAX), rlim_max: rlim_t(INT32_MAX))
    
let corelimit = UnsafeMutablePointer<rlimit>.allocate(capacity: 1)
corelimit.initialize(to: unlimited)
    
let coreType = Int32(RLIMIT_CORE.rawValue)
    
let status = setrlimit(coreType, corelimit)
if (status != 0) {
    print("\(errno)")
}
    
corelimit.deallocate(capacity: 1)
#endif

//Don't do SSL on macOS
#if os(Linux)
let mySSLConfig =  SSLConfig(withCACertificateFilePath: myChainPath, usingCertificateFile: myCertPath, withKeyFile: myKeyPath, usingSelfSignedCerts: false)
#endif

let APIKey: String
let rawAPIKey = getenv("APIKEY")
if let key = rawAPIKey, let keyString = String(utf8String: key) {
    APIKey = keyString
} else {
    APIKey = Default_APIKey
}

let router = Router()

//Log page responses
router.all { (request, response, next) in
    var previousOnEndInvoked: LifecycleHandler? = nil
    let onEndInvoked: LifecycleHandler = { [weak response, weak request] in
        Log.info("\(response?.statusCode.rawValue ?? 0) \(request?.originalURL ?? "unknown")")
        previousOnEndInvoked?()
    }
    previousOnEndInvoked = response.setOnEndInvoked(onEndInvoked    )
    next()
}

router.post("/api") { request, response, next in
    
    let bodyRaw: Data?
    do {
        bodyRaw = try BodyParser.readBodyData(with: request)
    } catch {
        Log.error("Could not read request body \(error)! Giving up!")
        response.headers["Content-Type"] = "text/plain; charset=utf-8"
        try? response.status(.preconditionFailed).send("Could not read request body \(error)! Giving up!").end()
        return
    }
    
    guard let bodyData = bodyRaw else {
        Log.error("Could not get bodyData from Raw Body! Giving up!")
        response.headers["Content-Type"] = "text/plain; charset=utf-8"
        try? response.status(.preconditionFailed).send("Could not get bodyData from Raw Body! Giving up!").end()
        return
    }
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = Point.iso8601Format
    
    let bodyPointArray: [Point]
    do {
        bodyPointArray = try Point.decodeJSON(data: bodyData)
    } catch {
        Log.error("Could not get Points from Body JSON! Giving up!")
        response.headers["Content-Type"] = "text/plain; charset=utf-8"
        try response.status(.preconditionFailed).send("Could not get Point from Body JSON \(error)! Giving up!").end()
        return
    }

    let fetchGroup = DispatchGroup()
    
    let dictUpdateQueue =
        DispatchQueue(
            label: "com.ibm.swift.dictUpdateQueue",
            attributes: .concurrent)
    
    var decorationsToReturn = [Decoration]()
    
    for model in bodyPointArray {
        
        fetchGroup.enter()
        
        guard let remoteURL = URL(string: "https://api.darksky.net/forecast/\(APIKey)/\(model.latitudeDegrees),\(model.longitudeDegrees),\(dateFormatter.string(from: model.datetime))") else {
            fatalError("Failed to create URL from hardcoded string")
        }

        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        
        let session = URLSession(configuration:URLSessionConfiguration.default)
        
        let task = session.dataTask(with: request){ fetchData,fetchResponse,fetchError in
            guard fetchError == nil else {
                Log.error(fetchError?.localizedDescription ?? "Error with no description")
                response.headers["Content-Type"] = "text/plain; charset=utf-8"
                try? response.status(.internalServerError).send(fetchError?.localizedDescription ?? "Error with no description").end()
                fetchGroup.leave()
                return
            }
            guard let fetchData = fetchData else {
                Log.error("Nil fetched data with no error")
                response.headers["Content-Type"] = "text/plain; charset=utf-8"
                try? response.status(.internalServerError).send("Nil fetched data with no error").end()
                fetchGroup.leave()
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: fetchData, options: .mutableContainers)
                
                if let debug = getenv("DEBUG") { //debug
                    //OK to crash if debugging turned on
                    let jsonForPrinting = try! JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                    let jsonToPrint = String(data: jsonForPrinting, encoding: .utf8)
                    print("result: \(jsonToPrint!)")
                }
                
                if let parseJSON = json as? [String: Any],
                    let hourlyDict:[String: Any] = parseJSON["hourly"] as? [String: Any],
                    let hourlySummary:String = hourlyDict["summary"] as? String {
                    print("hourlySummary: \(hourlySummary)")
                    let decoration = Decoration(title: hourlySummary, source: "DarkSky", point: model)
                    dictUpdateQueue.async(flags: .barrier) {
                        decorationsToReturn.append(decoration)
                        fetchGroup.leave()
                    }
                    return
                } else {
                    Log.error("Could not parse JSON payload as Dictionary")
                    response.headers["Content-Type"] = "text/plain; charset=utf-8"
                    try response.status(.internalServerError).send("Could not parse JSON payload as Dictionary").end()
                    fetchGroup.leave()
                    return
                }
            } catch {
                Log.error("Could not parse remote JSON Payload \(error)! Giving up!")
                response.headers["Content-Type"] = "text/plain; charset=utf-8"
                try? response.status(.internalServerError).send("Could not parse remote JSON Payload \(error)! Giving up!").end()
                fetchGroup.leave()
                return
            }
        }
        task.resume()
    }
    let timedout = fetchGroup.wait(timeout: DispatchTime.now() + 60)
    do {
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        response.status(.OK).send(data:try Decoration.encodeJSON(decorations: decorationsToReturn, dateFormatter: dateFormatter))
        next()
    } catch {
        Log.error("Could not create JSON Payload to return \(error)! Giving up!")
        response.headers["Content-Type"] = "text/plain; charset=utf-8"
        try? response.status(.internalServerError).send("Could not create JSON Payload to return \(error)! Giving up!").end()
    }
}

// Handles any errors that get set
router.error { request, response, next in
    response.headers["Content-Type"] = "text/plain; charset=utf-8"
    let errorDescription: String
    if let error = response.error {
        errorDescription = "\(error)"
    } else {
        errorDescription = "Unknown error"
    }
    response.headers["Content-Type"] = "text/plain; charset=utf-8"
    try response.send("Caught the error: \(errorDescription)").end()
}

//MARK: /ping
router.get("/ping") { request, response, next in
    //Health check
    response.headers["Content-Type"] = "text/plain; charset=utf-8"
    try response.send("OK").end()
}

//Don't do SSL on macOS
#if os(Linux)
Kitura.addHTTPServer(onPort: 8092, with: router, withSSL: mySSLConfig)
#else
Kitura.addHTTPServer(onPort: 8092, with: router)
#endif
Kitura.run()
