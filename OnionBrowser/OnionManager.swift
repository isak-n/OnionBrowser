//
//  OnionManager.swift
//  OnionBrowser2
//
//  Copyright © 2012 - 2021, Tigas Ventures, LLC (Mike Tigas)
//
//  This file is part of Onion Browser. See LICENSE file for redistribution terms.
//

import Foundation

protocol OnionManagerDelegate: AnyObject {

	func torConnProgress(_ progress: Int)

	func torConnFinished()

	func torConnDifficulties()
}

class OnionManager : NSObject {

	enum TorState {
		case none
		case started
		case connected
		case stopped
	}

	static let shared = OnionManager()

	// Show Tor log in iOS' app log.
	private static let TOR_LOGGING = false


	/**
	Basic Tor configuration.
	*/
	private static let torBaseConf: TorConfiguration = {
		let conf = TorConfiguration()
		conf.cookieAuthentication = true

		#if DEBUG
		let log_loc = "notice stdout"
		#else
		let log_loc = "notice file /dev/null"
		#endif

		conf.arguments = [
			"--allow-missing-torrc",
			"--ignore-missing-torrc",
			"--ClientOnly", "1",
			"--AvoidDiskWrites", "1",
			"--SocksPort", "127.0.0.1:39050",
			"--ControlPort", "127.0.0.1:39060",
			"--Log", log_loc,
			"--ClientUseIPv6", "1",
			"--ClientTransportPlugin", "obfs4 socks5 127.0.0.1:\(IPtProxyObfs4Port())",
			"--ClientTransportPlugin", "meek_lite socks5 127.0.0.1:\(IPtProxyMeekPort())",
			"--ClientTransportPlugin", "snowflake socks5 127.0.0.1:\(IPtProxySnowflakePort())",
			"--GeoIPFile", Bundle.main.path(forResource: "geoip", ofType: nil) ?? "",
			"--GeoIPv6File", Bundle.main.path(forResource: "geoip6", ofType: nil) ?? "",
		]


		// Store data in <appdir>/Library/Caches/tor (Library/Caches/ is for things that can persist between
		// launches -- which we'd like so we keep descriptors & etc -- but don't need to be backed up because
		// they can be regenerated by the app)
		if let dataDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
			.first?.appendingPathComponent("tor", isDirectory: true) {

			#if DEBUG
			print("[\(String(describing: OnionManager.self))] dataDir=\(dataDir)")
			#endif

			// Create tor data directory if it does not yet exist.
			try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

			// Create Tor v3 auth directory if it does not yet exist.
			let authDir = dataDir.appendingPathComponent("auth", isDirectory: true)

			try? FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)

			conf.dataDirectory = dataDir

			conf.arguments += ["--ClientOnionAuthDir", authDir.path]
		}

		return conf
	}()


	// MARK: Built-in configuration options

	static let obfs4Bridges = NSArray(contentsOfFile: Bundle.main.path(forResource: "obfs4-bridges", ofType: "plist")!) as! [String]

	/**
	Don't use anymore: Microsoft announced to start blocking domain fronting!

	[Microsoft: Securing our approach to domain fronting within Azure](https://www.microsoft.com/security/blog/2021/03/26/securing-our-approach-to-domain-fronting-within-azure/)
	*/
	@available(*, deprecated)
	static let meekAzureBridge = [
		"meek_lite 0.0.2.0:3 97700DFE9F483596DDA6264C4D7DF7641E1E39CE url=https://meek.azureedge.net/ front=ajax.aspnetcdn.com"
	]

	static let snowflakeBridge = [
		// BUGFIX: The fingerprint of flakey needs to be there, otherwise,
		// bootstrapping Tor with Snowflake is impossible.
		// https://gitlab.torproject.org/tpo/core/tor/-/issues/40360
		//
		// The IP address is a reserved one, btw. Only there to fulfill Tor Bridge line requirements.
		// The actual config is done in #startSnowflake.
		"snowflake 192.0.2.3:1 2B280B23E1107BB62ABFC40DDCC8824814F80A72"
	]


	// MARK: OnionManager instance

	public var state = TorState.none

	public lazy var onionAuth: TorOnionAuth? = {
		guard let args = OnionManager.torBaseConf.arguments,
			  let i = args.firstIndex(of: "--ClientOnionAuthDir"),
			  args.count > i + 1
		else {
			return nil
		}

		return TorOnionAuth(dir: args[i + 1])
	}()

	private var torController: TorController?

	private var torThread: TorThread?

	private var initRetry: DispatchWorkItem?

	private var bridgesType = Settings.BridgesType.none
	private var customBridges: [String]?
	private var needsReconfiguration = false

	private var cookie: Data? {
		if let cookieUrl = OnionManager.torBaseConf.dataDirectory?.appendingPathComponent("control_auth_cookie") {
			return try? Data(contentsOf: cookieUrl)
		}

		return nil
	}

	override init() {
		super.init()

		NotificationCenter.default.addObserver(self, selector: #selector(networkChange),
											   name: .reachabilityChanged, object: nil)
	}


	// MARK: Reachability

	@objc
	func networkChange() {
		print("[\(String(describing: type(of: self)))] ipv6_status: \(Ipv6Tester.ipv6_status())")
		var confs:[Dictionary<String,String>] = []

		if (Ipv6Tester.ipv6_status() == TOR_IPV6_CONN_ONLY) {
			// We think we're on a IPv6-only DNS64/NAT64 network.
			confs.append(["key": "ClientPreferIPv6ORPort", "value": "1"])

			if (self.bridgesType != .none) {
				// Bridges on, leave IPv4 on.
				// User's bridge config contains all the IPs (v4 or v6)
				// that we connect to, so we let _that_ setting override our
				// "IPv6 only" self-test.
				confs.append(["key": "ClientUseIPv4", "value": "1"])
			}
			else {
				// Otherwise, for IPv6-only no-bridge state, disable IPv4
				// connections from here to entry/guard nodes.
				//(i.e. all outbound connections are IPv6 only.)
				confs.append(["key": "ClientUseIPv4", "value": "0"])
			}
		} else {
			// default mode
			confs.append(["key": "ClientPreferIPv6DirPort", "value": "auto"])
			confs.append(["key": "ClientPreferIPv6ORPort", "value": "auto"])
			confs.append(["key": "ClientUseIPv4", "value": "1"])
		}

		torController?.setConfs(confs, completion: { _, _ in
			self.torReconnect()
		})
	}


	// MARK: Public Methods

	/**
	Set bridges configuration and evaluate, if the new configuration is actually different
	then the old one.

	- parameter bridgesType: the selected ID as defined in OBSettingsConstants.
	- parameter customBridges: a list of custom bridges the user configured.
	*/
	func setBridgeConfiguration(bridgesType: Settings.BridgesType, customBridges: [String]?) {
		needsReconfiguration = bridgesType != self.bridgesType

		if !needsReconfiguration {
			if let oldVal = self.customBridges, let newVal = customBridges {
				needsReconfiguration = oldVal != newVal
			}
			else{
				needsReconfiguration = (self.customBridges == nil && customBridges != nil) ||
					(self.customBridges != nil && customBridges == nil)
			}
		}

		self.bridgesType = bridgesType
		self.customBridges = customBridges
	}

	func torReconnect(_ callback: ((_ success: Bool) -> Void)? = nil) {
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

	func startObfs4proxy() {
		#if DEBUG
		let ennableLogging = true
		#else
		let ennableLogging = false
		#endif

		IPtProxyStartObfs4Proxy("DEBUG", ennableLogging, true, nil)

		stopSnowflake()
	}

	func stopObfs4proxy() {
		print("[\(String(describing: type(of: self)))] #stopObfs4proxy")

		IPtProxyStopObfs4Proxy()
	}

	/**
	See [Update domain front for Snowflake](https://gitlab.torproject.org/tpo/applications/tor-browser-build/-/commit/663a42c51fde05d7f0ee26e01c408a86f863622c)
	*/
	func startSnowflake() {
		IPtProxyStartSnowflake(
			"stun:stun.l.google.com:19302,stun:stun.voip.blackberry.com:3478,stun:stun.altar.com.pl:3478,stun:stun.antisip.com:3478,stun:stun.bluesip.net:3478,stun:stun.dus.net:3478,stun:stun.epygi.com:3478,stun:stun.sonetel.com:3478,stun:stun.sonetel.net:3478,stun:stun.stunprotocol.org:3478,stun:stun.uls.co.za:3478,stun:stun.voipgate.com:3478,stun:stun.voys.nl:3478",
			"https://snowflake-broker.torproject.net.global.prod.fastly.net/",
			"cdn.sstatic.net", nil, true, false, true, 1)

		stopObfs4proxy()
	}

	func stopSnowflake() {
		print("[\(String(describing: type(of: self)))] #stopSnowflake")

		IPtProxyStopSnowflake()
	}

	func startTor(delegate: OnionManagerDelegate?) {
		// Avoid a retain cycle. Only use the weakDelegate in closures!
		weak var weakDelegate = delegate

		cancelInitRetry()
		state = .started

		if (self.torController == nil) {
			self.torController = TorController(socketHost: "127.0.0.1", port: 39060)
		}

		let reach = Reachability.forInternetConnection()
		reach?.startNotifier()

		if torThread?.isCancelled ?? true {
			torThread = nil

			let torConf = OnionManager.torBaseConf

			var args = torConf.arguments!

			// Add user-defined configuration.
			args += Settings.advancedTorConf ?? []

			args += getBridgesAsArgs()

			// configure ipv4/ipv6
			// Use Ipv6Tester. If we _think_ we're IPv6-only, tell Tor to prefer IPv6 ports.
			// (Tor doesn't always guess this properly due to some internal IPv4 addresses being used,
			// so "auto" sometimes fails to bootstrap.)
			print("[\(String(describing: OnionManager.self))] ipv6_status: \(Ipv6Tester.ipv6_status())")
			if (Ipv6Tester.ipv6_status() == TOR_IPV6_CONN_ONLY) {
				args += ["--ClientPreferIPv6ORPort", "1"]

				if bridgesType != .none {
					// Bridges on, leave IPv4 on.
					// User's bridge config contains all the IPs (v4 or v6)
					// that we connect to, so we let _that_ setting override our
					// "IPv6 only" self-test.
					args += ["--ClientUseIPv4", "1"]
				}
				else {
					// Otherwise, for IPv6-only no-bridge state, disable IPv4
					// connections from here to entry/guard nodes.
					// (i.e. all outbound connections are ipv6 only.)
					args += ["--ClientUseIPv4", "0"]
				}
			}
			else {
				args += [
					"--ClientPreferIPv6ORPort", "auto",
					"--ClientUseIPv4", "1",
				]
			}

			#if DEBUG
			print("[\(String(describing: type(of: self)))] arguments=\(String(describing: args))")
			#endif

			torConf.arguments = args
			torThread = TorThread(configuration: torConf)
			needsReconfiguration = false

			torThread?.start()

			print("[\(String(describing: type(of: self)))] Starting Tor")
		}
		else {
			if needsReconfiguration {
				let conf = getBridgesAsConf()

				torController?.resetConf(forKey: "Bridge")

				if conf.count > 0 {
					// Bridges need to be set *before* "UseBridges"="1"!
					torController?.setConfs(conf)
					torController?.setConfForKey("UseBridges", withValue: "1")
				}
				else {
					torController?.setConfForKey("UseBridges", withValue: "0")
				}
			}
		}

		// Wait long enough for Tor itself to have started. It's OK to wait for this
		// because Tor is already trying to connect; this is just the part that polls for
		// progress.
		DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {
			if OnionManager.TOR_LOGGING {
				// Show Tor log in iOS' app log.
				TORInstallTorLoggingCallback { severity, msg in
					let s: String

					switch severity {
					case .debug:
						s = "debug"

					case .error:
						s = "error"

					case .fault:
						s = "fault"

					case .info:
						s = "info"

					default:
						s = "default"
					}

					print("[Tor \(s)] \(String(cString: msg).trimmingCharacters(in: .whitespacesAndNewlines))")
				}
				TORInstallEventLoggingCallback { severity, msg in
					let s: String

					switch severity {
					case .debug:
						// Ignore libevent debug messages. Just too many of typically no importance.
						return

					case .error:
						s = "error"

					case .fault:
						s = "fault"

					case .info:
						s = "info"

					default:
						s = "default"
					}

					print("[libevent \(s)] \(String(cString: msg).trimmingCharacters(in: .whitespacesAndNewlines))")
				}
			}

			if !(self.torController?.isConnected ?? false) {
				do {
					try self.torController?.connect()
				} catch {
					print("[\(String(describing: OnionManager.self))] error=\(error)")
				}
			}

			guard let cookie = self.cookie else {
				print("[\(String(describing: type(of: self)))] Could not connect to Tor - cookie unreadable!")

				return
			}

			#if DEBUG
			print("[\(String(describing: type(of: self)))] cookie=", cookie.base64EncodedString())
			#endif

			self.torController?.authenticate(with: cookie, completion: { success, error in
				if success {
					var completeObs: Any?
					completeObs = self.torController?.addObserver(forCircuitEstablished: { established in
						if established {
							self.state = .connected
							self.torController?.removeObserver(completeObs)
							self.cancelInitRetry()
							#if DEBUG
							print("[\(String(describing: type(of: self)))] Connection established!")
							#endif

							weakDelegate?.torConnFinished()
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

							weakDelegate?.torConnProgress(progress)

							if progress >= 100 {
								self.torController?.removeObserver(progressObs)
							}

							return true
						}

						return false
					}) // torController.addObserver
				} // if success (authenticate)
				else {
					print("[\(String(describing: type(of: self)))] Didn't connect to control port.")
				}
			}) // controller authenticate
		}) //delay

		initRetry = DispatchWorkItem {
			// Only do this, if we're not running over a bridge, it will close
			// the connection to the bridge client which will close or break the bridge client!
			if self.bridgesType == .none {
				#if DEBUG
				print("[\(String(describing: type(of: self)))] Triggering Tor connection retry.")
				#endif

				self.torController?.setConfForKey("DisableNetwork", withValue: "1")
				self.torController?.setConfForKey("DisableNetwork", withValue: "0")
			}

			// Hint user that they might need to use a bridge.
			delegate?.torConnDifficulties()
		}

		// On first load: If Tor hasn't finished bootstrap in 30 seconds,
		// HUP tor once in case we have partially bootstrapped but got stuck.
		DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: initRetry!)

	}// startTor

	/**
	Shuts down Tor.
	*/
	func stopTor() {
		print("[\(String(describing: type(of: self)))] #stopTor")

		// Under the hood, TORController will SIGNAL SHUTDOWN and set it's channel to nil, so
		// we actually rely on that to stop Tor and reset the state of torController. (we can
		// SIGNAL SHUTDOWN here, but we can't reset the torController "isConnected" state.)
		torController?.disconnect()
		torController = nil

		// More cleanup
		torThread?.cancel()
		torThread = nil

		stopObfs4proxy()
		stopSnowflake()

		state = .stopped
	}

	/**
	 Will make Tor reload its configuration, if it's already running or start (again), if not.

	 This is needed, when bridge configuration changed, or when v3 onion service authentication keys
	 are added.

	 When such keys are removed, that's unfortunately not enough. Only a full stop and restart will do.
	 But still being able to access auhtenticated Onion services after removing the key doesn't seem
	 to be such a huge deal compared to not being able to access it despite having added the key.

	 So that should be good enough?
	 */
	func reloadTor(delegate: OnionManagerDelegate? = nil) {
		needsReconfiguration = true

		startTor(delegate: delegate)
	}


	// MARK: Private Methods

	/**
	- returns: The list of bridges which is currently configured to be valid.
	*/
	private func getBridges() -> [String] {
		#if DEBUG
		print("[\(String(describing: type(of: self)))] bridgesId=\(bridgesType)")
		#endif

		switch bridgesType {
		case .obfs4:
			startObfs4proxy()
			return OnionManager.obfs4Bridges

		case .snowflake:
			startSnowflake()
			return OnionManager.snowflakeBridge

		case .custom:
			startObfs4proxy()
			return customBridges ?? []

		default:
			stopObfs4proxy()
			stopSnowflake()
			return []
		}
	}

	/**
	- returns: The list of bridges which is currently configured to be valid *as argument list* to be used on Tor startup.
	*/
	private func getBridgesAsArgs() -> [String] {
		var args = [String]()

		for bridge in getBridges() {
			args += ["--Bridge", bridge]
		}

		if args.count > 0 {
			args.append(contentsOf: ["--UseBridges", "1"])
		}

		return args
	}

	/**
	Each bridge line needs to be wrapped in double-quotes (").

	- returns: The list of bridges which is currently configured to be valid *as configuration list* to be used with `TORController#setConfs`.
	*/
	private func getBridgesAsConf() -> [[String: String]] {
		return getBridges().map { ["key": "Bridge", "value": "\"\($0)\""] }
	}

	/**
	Cancel the connection retry and fail guard.
	*/
	private func cancelInitRetry() {
		initRetry?.cancel()
		initRetry = nil
	}
}
