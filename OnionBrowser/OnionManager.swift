/*
 * Onion Browser
 * Copyright (c) 2012-2018, Tigas Ventures, LLC (Mike Tigas)
 *
 * This file is part of Onion Browser. See LICENSE file for redistribution terms.
 */

import Foundation

@objc class OnionManager : NSObject {

    @objc enum TorState: Int {
        case none
        case started
        case connected
        case stopped
    }

    @objc static let shared = OnionManager()

    // Show Tor log in iOS' app log.
    private static let TOR_LOGGING = false

    private static let TOR_IPV6_CONN_FALSE = 0
    private static let TOR_IPV6_CONN_DUAL = 1
    private static let TOR_IPV6_CONN_ONLY = 2
    private static let TOR_IPV6_CONN_UNKNOWN = 99

    private static let torBaseConf: TorConfiguration = {

        // Store data in <appdir>/Library/Caches/tor (Library/Caches/ is for things that can persist between
        // launches -- which we'd like so we keep descriptors & etc -- but don't need to be backed up because
        // they can be regenerated by the app)
        let filemgr = FileManager.default
        let dirPaths = filemgr.urls(for: .cachesDirectory, in: .userDomainMask)
        let docsDir = dirPaths[0].path

        let dataDir = URL(fileURLWithPath: docsDir, isDirectory: true).appendingPathComponent("tor", isDirectory: true)

        #if DEBUG
            print("[\(String(describing: OnionManager.self))] dataDir=\(dataDir)");
        #endif

        // Create tor data directory if it does not yet exist
        do {
            try FileManager.default.createDirectory(atPath: dataDir.path, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            print("[\(String(describing: OnionManager.self))] error=\(error.localizedDescription))")
        }
        // Create tor v3 auth directory if it does not yet exist
        let authDir = URL(fileURLWithPath: dataDir.path, isDirectory: true).appendingPathComponent("auth", isDirectory: true)
        do {
            try FileManager.default.createDirectory(atPath: authDir.path, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            print("[\(String(describing: OnionManager.self))] error=\(error.localizedDescription))")
        }
        // TODO: pref pane for adding "<sitename>.auth_private" files to this directory
        
        // Configure tor and return the configuration object
        let configuration = TorConfiguration()
        configuration.cookieAuthentication = true
        configuration.dataDirectory = dataDir

        #if DEBUG
            let log_loc = "notice stdout"
        #else
            let log_loc = "notice file /dev/null"
        #endif

        var config_args = [
            "--allow-missing-torrc",
            "--ignore-missing-torrc",
            "--clientonly", "1",
            "--socksport", "39050",
            "--controlport", "127.0.0.1:39060",
//            "--HashedControlPassword", "16:1427783EE4FFA03B60A19E6625D3F28EC59943393CC80FABF3CC7FF18A",
            "--log", log_loc,
            "--clientuseipv6", "1",
            "--ClientTransportPlugin", "obfs4 socks5 127.0.0.1:47351",
            "--ClientTransportPlugin", "meek_lite socks5 127.0.0.1:47352",
            "--ClientOnionAuthDir", authDir.path,
            "--GeoIPFile", Bundle.main.path(forResource: "geoip", ofType: nil) ?? "",
            "--GeoIPv6File", Bundle.main.path(forResource: "geoip6", ofType: nil) ?? "",
        ]

        configuration.arguments = config_args
        return configuration
    }()

    // MARK: - Built-in configuration options

    private static let obfs4Bridges = NSArray(contentsOfFile: Bundle.main.path(forResource: "obfs4-bridges", ofType: "plist")!) as! [String]

    public static let meekAzureBridges = [
        "meek_lite 0.0.2.0:3 97700DFE9F483596DDA6264C4D7DF7641E1E39CE url=https://meek.azureedge.net/ front=ajax.aspnetcdn.com"
    ]

    // MARK: - OnionManager instance

    private var torController: TorController?
    private let obfsproxy = ObfsThread()


    private var torThread: TorThread?

    @objc public var state = TorState.none
    private var initRetry: DispatchWorkItem?
    private var failGuard: DispatchWorkItem?

    private var bridgesId: Int?
    private var customBridges: [String]?
    private var needsReconfiguration: Bool = false

    /**
        Set bridges configuration and evaluate, if the new configuration is actually different
        then the old one.

         - parameter bridgesId: the selected ID as defined in OBSettingsConstants.
         - parameter customBridges: a list of custom bridges the user configured.
    */
    @objc func setBridgeConfiguration(bridgesId: Int, customBridges: [String]?) {
        needsReconfiguration = bridgesId != self.bridgesId ?? USE_BRIDGES_NONE

        if !needsReconfiguration {
            if let oldVal = self.customBridges, let newVal = customBridges {
                needsReconfiguration = oldVal != newVal
            }
            else{
                needsReconfiguration = (self.customBridges == nil && customBridges != nil) ||
                    (self.customBridges != nil && customBridges == nil)
            }
        }

        self.bridgesId = bridgesId
        self.customBridges = customBridges
    }
    
    @objc func networkChange() {
        print("[\(String(describing: OnionManager.self))] ipv6_status: \(Ipv6Tester.ipv6_status())")
        var confs:[Dictionary<String,String>] = []

        if (Ipv6Tester.ipv6_status() == OnionManager.TOR_IPV6_CONN_ONLY) {
            // we think we're on a ipv6-only DNS64/NAT64 network
            confs.append(["key":"ClientPreferIPv6ORPort", "value":"1"])
            if (self.bridgesId != nil && self.bridgesId != USE_BRIDGES_NONE) {
                // bridges on, leave ipv4 on.
                // user's bridge config contains all the IPs (v4 or v6)
                // that we connect to, so we let _that_ setting override our
                // "ipv6 only" self-test.
                confs.append(["key":"clientuseipv4", "value":"1"])
            } else {
                // otherwise, for ipv6-only no-bridge state, disable ipv4
                // connections from here to entry/guard
                // nodes. (i.e. all outbound connections are ipv6 only.)
                confs.append(["key":"clientuseipv4", "value":"0"])
            }
        } else {
            // default mode
            confs.append(["key":"ClientPreferIPv6DirPort", "value":"auto"])
            confs.append(["key":"ClientPreferIPv6ORPort", "value":"auto"])
            confs.append(["key":"clientuseipv4", "value":"1"])
        }
        
        torController?.setConfs(confs, completion: { (_, _) in
			self.torReconnect()
        })
    }

	@objc func torReconnect(_ callback: ((_ success: Bool) -> Void)? = nil) {
		torController?.resetConnection(callback)
    }

	func closeCircuits(_ circuits: [TorCircuit], _ callback: @escaping ((_ success: Bool) -> Void)) {
		torController?.close(circuits, completion: callback)
	}

	/**
	Get all fully built circuits and detailed info about their nodes.

	- parameter callback: Called, when all info is available.
	- parameter circuits: A list of circuits and the nodes they consist of.
	*/
	func getCircuits(_ callback: @escaping ((_ circuits: [TorCircuit]) -> Void)) {
		torController?.getCircuits(callback)
	}

    @objc func startTor(delegate: OnionManagerDelegate?) {
        cancelInitRetry()
        cancelFailGuard()
        state = .started
        
        if (self.torController == nil) {
            self.torController = TorController(socketHost: "127.0.0.1", port: 39060)
        }

        let reach:Reachability = Reachability.forInternetConnection()
        NotificationCenter.default.addObserver(self, selector: #selector(self.networkChange), name: NSNotification.Name.reachabilityChanged, object: nil)
        reach.startNotifier()

        if ((self.torThread == nil) || (self.torThread?.isCancelled ?? true)) {
            self.torThread = nil
            
            let torConf = OnionManager.torBaseConf

            var args = torConf.arguments!

            // configure bridge lines, if necessary
            #if DEBUG
                print("[\(String(describing: OnionManager.self))] bridgesId=\(bridgesId ?? -1)")
            #endif

            if bridgesId != nil && bridgesId != USE_BRIDGES_NONE {
                args.append("--usebridges")
                args.append("1")
                switch bridgesId! {
                case USE_BRIDGES_OBFS4:
                    args += bridgeLinesToArgs(OnionManager.obfs4Bridges)
                case USE_BRIDGES_MEEKAZURE:
                    args += bridgeLinesToArgs(OnionManager.meekAzureBridges)
                default:
                    if customBridges != nil {
                        args += bridgeLinesToArgs(customBridges!)
                    }
                }
            }

            // configure ipv4/ipv6
            // Use Ipv6Tester. If we _think_ we're IPv6-only, tell Tor to prefer IPv6 ports.
            // (Tor doesn't always guess this properly due to some internal IPv4 addresses being used,
            // so "auto" sometimes fails to bootstrap.)
            print("[\(String(describing: OnionManager.self))] ipv6_status: \(Ipv6Tester.ipv6_status())")
            if (Ipv6Tester.ipv6_status() == OnionManager.TOR_IPV6_CONN_ONLY) {
                args += [
                    "--ClientPreferIPv6ORPort", "1",
                ]
                if bridgesId != nil && bridgesId != USE_BRIDGES_NONE {
                    // bridges on, leave ipv4 on.
                    // user's bridge config contains all the IPs (v4 or v6)
                    // that we connect to, so we let _that_ setting override our
                    // "ipv6 only" self-test.
                    args += ["--clientuseipv4", "1"]
                } else {
                    // otherwise, for ipv6-only no-bridge state, disable ipv4
                    // connections from here to entry/guard
                    // nodes. (i.e. all outbound connections are ipv6 only.)
                    args += ["--clientuseipv4", "0"]
                }
            } else {
                args += [
                    "--ClientPreferIPv6ORPort", "auto",
                    "--clientuseipv4", "1",
                ]
            }

            #if DEBUG
                dump("\n\n\(String(describing: args))\n\n")
            #endif
            torConf.arguments = args
            self.torThread = TorThread(configuration: torConf)
            needsReconfiguration = false

            self.torThread!.start()

            if !self.obfsproxy.isExecuting && !self.obfsproxy.isCancelled && !self.obfsproxy.isFinished {
                self.obfsproxy.start()
            }

            print("[\(String(describing: OnionManager.self))] Starting Tor")
        }
        else {
            if needsReconfiguration {
                if bridgesId == nil || bridgesId == USE_BRIDGES_NONE {
                    // Not using bridges, so null out the "Bridge" conf
                    torController!.setConfForKey("usebridges", withValue: "0", completion: { (_, _) in
                    })
                    torController!.resetConf(forKey: "bridge", completion: { (_, _) in
                    })
                } else {
                    var bridges:Array<String> = []
                    var confs:[Dictionary<String,String>] = []

                    switch bridgesId! {
                    case USE_BRIDGES_OBFS4:
                        bridges = OnionManager.obfs4Bridges
                    case USE_BRIDGES_MEEKAZURE:
                        bridges = OnionManager.meekAzureBridges
                    default:
                        if customBridges != nil {
                            bridges = customBridges!
                        }
                    }

                    // wrap each bridge line in double-quotes (")
                    let quoted_bridges = bridges.map({ (bridge:String) -> String in
                        return "\"\(bridge)\""
                    })
                    for (_, bridge_arg) in quoted_bridges.enumerated() {
                        confs.append(["key":"bridge", "value":bridge_arg])
                    }

                    // Ensure we set UseBridges=1
                    self.torController!.setConfForKey("usebridges", withValue: "1", completion: { (_, _) in
                    })

                    // Clear existing bridge conf and then set the new bridge configs.
                    self.torController!.resetConf(forKey: "bridge", completion: { (_, _) in
                    })
                    self.torController!.setConfs(confs, completion: { (_, _) in
                    })

                }

            }
        }

        // Wait long enough for tor itself to have started. It's OK to wait for this
        // because Tor is already trying to connect; this is just the part that polls for
        // progress.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {
            if OnionManager.TOR_LOGGING {
                // Show Tor log in iOS' app log.
                TORInstallTorLogging()
                TORInstallEventLogging()
            }

            if !(self.torController?.isConnected ?? false) {
                do {
                    try self.torController?.connect()
                } catch {
                    print("[\(String(describing: OnionManager.self))] error=\(error)")
                }
            }

            let cookieURL = OnionManager.torBaseConf.dataDirectory!.appendingPathComponent("control_auth_cookie")
            let cookie = try! Data(contentsOf: cookieURL)

            #if DEBUG
                print("[\(String(describing: OnionManager.self))] cookieURL=", cookieURL as Any)
                print("[\(String(describing: OnionManager.self))] cookie=", cookie)
            #endif

            self.torController?.authenticate(with: cookie, completion: { (success, error) in
                if success {
                    var completeObs: Any?
                    completeObs = self.torController?.addObserver(forCircuitEstablished: { (established) in
                        if established {
                            self.state = .connected
                            self.torController?.removeObserver(completeObs)
                            self.cancelInitRetry()
                            self.cancelFailGuard()
                            #if DEBUG
                                print("[\(String(describing: OnionManager.self))] connection established")
                            #endif

                            delegate?.torConnFinished()
                        }
                    }) // torController.addObserver

                    var progressObs: Any?
                    progressObs = self.torController?.addObserver(forStatusEvents: {
                        (type: String, severity: String, action: String, arguments: [String : String]?) -> Bool in

                        if type == "STATUS_CLIENT" && action == "BOOTSTRAP" {
                            let progress = Int(arguments!["PROGRESS"]!)!
                            #if DEBUG
                                print("[\(String(describing: OnionManager.self))] progress=\(progress)")
                            #endif

                            delegate?.torConnProgress(progress)

                            if progress >= 100 {
                                self.torController?.removeObserver(progressObs)
                            }

                            return true;
                        }

                        return false;
                    }) // torController.addObserver
                } // if success (authenticate)
                else { print("[\(String(describing: OnionManager.self))] Didn't connect to control port.") }
            }) // controller authenticate
        }) //delay

        initRetry = DispatchWorkItem {
            #if DEBUG
                print("[\(String(describing: OnionManager.self))] Triggering Tor connection retry.")
            #endif
            self.torController?.setConfForKey("DisableNetwork", withValue: "1", completion: { (_, _) in
            })

            self.torController?.setConfForKey("DisableNetwork", withValue: "0", completion: { (_, _) in
            })

            self.failGuard = DispatchWorkItem {
                if self.state != .connected {
                    delegate?.torConnError()
                }
            }

            // Show error to user, when, after 90 seconds (30 sec + one retry of 60 sec), Tor has still not started.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: self.failGuard!)
        }

        // On first load: If Tor hasn't finished bootstrap in 30 seconds,
        // HUP tor once in case we have partially bootstrapped but got stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: initRetry!)

    }// startTor

    /**
     Experimental Tor shutdown.
    */
    @objc func stopTor() {
        print("[\(String(describing: OnionManager.self))] #stopTor")
        
        // under the hood, TORController will SIGNAL SHUTDOWN and set it's channel to nil, so
        // we actually rely on that to stop tor and reset the state of torController. (we can
        // SIGNAL SHUTDOWN here, but we can't reset the torController "isConnected" state.)
        self.torController?.disconnect()
        
        self.torController = nil
        
        // More cleanup
        self.torThread?.cancel()
        self.state = .stopped
    }

    private func bridgeLinesToArgs(_ bridgeLines: [String]) -> [String] {
        var bridges: [String] = []
        for (_, element) in bridgeLines.enumerated() {
            bridges.append("--bridge")
            bridges.append(element)
        }

        return bridges
    }

    /**
        Cancel the connection retry
     */
    private func cancelInitRetry() {
        initRetry?.cancel()
        initRetry = nil
    }
    /**
        Cancel the fail guard.
     */
    private func cancelFailGuard() {
        failGuard?.cancel()
        failGuard = nil
    }
}
