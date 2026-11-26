// XuESP Console native macOS plugin: compiled into the Xu UI host by `xu build --desktop`.
// Owns ESP32 cluster management, BLE HID command console, macros, and CoreBluetooth
// Wi-Fi/MQTT provisioning for XuPlay-Setup-* ESP32 nodes.

import AppKit
import CoreBluetooth
import Darwin

enum EspTheme {
  static let canvasBg = NSColor(srgbRed: 0.043, green: 0.051, blue: 0.067, alpha: 1.0)
  static let panelBg = NSColor(srgbRed: 0.075, green: 0.086, blue: 0.114, alpha: 1.0)
  static let elevatedBg = NSColor(srgbRed: 0.110, green: 0.125, blue: 0.161, alpha: 1.0)
  static let border = NSColor(srgbRed: 0.145, green: 0.165, blue: 0.212, alpha: 1.0)
  static let textPrimary = NSColor(srgbRed: 0.953, green: 0.961, blue: 0.973, alpha: 1.0)
  static let textSecondary = NSColor(srgbRed: 0.608, green: 0.639, blue: 0.706, alpha: 1.0)
  static let emerald = NSColor(srgbRed: 0.063, green: 0.725, blue: 0.506, alpha: 1.0)
  static let accentBlue = NSColor(srgbRed: 0.231, green: 0.510, blue: 0.965, alpha: 1.0)
  static let danger = NSColor(srgbRed: 0.937, green: 0.267, blue: 0.267, alpha: 1.0)
}

struct EspTargetDevice {
  var id: String
  var phoneName: String
  var mqttTopic: String
  var bleSlot: Int
  var blePeer: String
  var group: String
}

// MARK: - Loopback WebSocket Client

final class LoopbackWSClient {
  static func request(port: UInt16, jsonString: String, timeoutMs: Int = 6000) -> [String: Any]? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    defer { close(fd) }

    var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if rc != 0 { return nil }

    let handshake =
      "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    guard writeAll(fd, Array(handshake.utf8)) else { return nil }

    var headerBuf = [UInt8]()
    var one = [UInt8](repeating: 0, count: 1)
    while headerBuf.count < 4096 {
      let r = read(fd, &one, 1)
      if r <= 0 { return nil }
      headerBuf.append(one[0])
      let n = headerBuf.count
      if n >= 4 && headerBuf[n - 4] == 13 && headerBuf[n - 3] == 10 && headerBuf[n - 2] == 13 && headerBuf[n - 1] == 10 {
        break
      }
    }

    let payload = Array(jsonString.utf8)
    var frame = [UInt8]()
    frame.append(0x81)
    let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
    if payload.count < 126 {
      frame.append(UInt8(payload.count) | 0x80)
    } else if payload.count < 65536 {
      frame.append(126 | 0x80)
      frame.append(UInt8((payload.count >> 8) & 0xFF))
      frame.append(UInt8(payload.count & 0xFF))
    } else {
      return nil
    }
    frame.append(contentsOf: mask)
    for i in 0..<payload.count {
      frame.append(payload[i] ^ mask[i & 3])
    }
    guard writeAll(fd, frame) else { return nil }

    guard let hdr = readExact(fd, 2) else { return nil }
    let code = Int(hdr[1] & 0x7F)
    var plen = code
    if code == 126 {
      guard let ext = readExact(fd, 2) else { return nil }
      plen = (Int(ext[0]) << 8) | Int(ext[1])
    } else if code == 127 {
      guard let ext = readExact(fd, 8) else { return nil }
      plen = 0
      for b in ext { plen = (plen << 8) | Int(b) }
    }
    if (hdr[1] & 0x80) != 0 {
      _ = readExact(fd, 4)
    }
    guard plen >= 0, plen <= 4_194_304, let body = readExact(fd, plen) else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
  }

  private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
      let n = bytes.withUnsafeBytes { raw in
        write(fd, raw.baseAddress! + off, bytes.count - off)
      }
      if n <= 0 { return false }
      off += n
    }
    return true
  }

  private static func readExact(_ fd: Int32, _ count: Int) -> [UInt8]? {
    if count == 0 { return [] }
    var out = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
      let r = out.withUnsafeMutableBytes { raw in
        read(fd, raw.baseAddress! + got, count - got)
      }
      if r <= 0 { return nil }
      got += r
    }
    return out
  }
}

// MARK: - BLE Provisioning Center (CoreBluetooth)

final class ProvisionManager: NSObject {
  static let shared = ProvisionManager()

  private let serviceUUID = CBUUID(string: "FF00")
  private let configUUID = CBUUID(string: "FF01")
  private let statusUUID = CBUUID(string: "FF02")

  private var central: CBCentralManager?
  private var found: [String: CBPeripheral] = [:]
  private var rssi: [String: Int] = [:]
  private var target: CBPeripheral?
  private var configChar: CBCharacteristic?
  private var statusChar: CBCharacteristic?
  private var onResult: ((String) -> Void)?
  private var scanning = false
  private var pendingConfig: Data?

  func scan(onResult: @escaping (String) -> Void) {
    self.onResult = onResult
    found.removeAll()
    rssi.removeAll()
    let manager = central ?? CBCentralManager(delegate: self, queue: .main)
    central = manager
    if manager.state == .poweredOn {
      startScan()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
      self?.finishScan()
    }
  }

  func write(device: String, config: [String: String], onResult: @escaping (String) -> Void) {
    self.onResult = onResult
    let manager = central ?? CBCentralManager(delegate: self, queue: .main)
    central = manager
    guard manager.state == .poweredOn else {
      report(["action": "write", "state": "failed", "message": "Bluetooth is off"])
      return
    }
    guard let peripheral = found[device] else {
      report(["action": "write", "state": "failed", "message": "device not found: \(device)"])
      return
    }
    target = peripheral
    configChar = nil
    statusChar = nil
    var payload: [String: String] = [:]
    payload["ssid"] = config["ssid"] ?? ""
    payload["pass"] = config["pass"] ?? ""
    payload["mqtt_uri"] = config["mqtt_uri"] ?? ""
    payload["root"] = config["root"] ?? ""
    payload["name"] = config["name"] ?? ""
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
      report(["action": "write", "state": "failed", "message": "bad configuration"])
      return
    }
    pendingConfig = data
    peripheral.delegate = self
    manager.connect(peripheral, options: nil)
  }

  private func startScan() {
    guard let manager = central, manager.state == .poweredOn, !scanning else { return }
    scanning = true
    manager.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
  }

  private func finishScan() {
    guard let manager = central, scanning else { return }
    scanning = false
    manager.stopScan()
    var list: [[String: Any]] = []
    for (name, _) in found.sorted(by: { $0.key < $1.key }) {
      list.append(["name": name, "rssi": rssi[name] ?? 0])
    }
    report(["action": "scan", "state": "done", "devices": list])
  }

  private func report(_ fields: [String: Any]) {
    var payload = fields
    payload["op"] = "provision_result"
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: data, encoding: .utf8) else { return }
    onResult?(text)
  }
}

extension ProvisionManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn {
      startScan()
    } else {
      report(["action": "scan", "state": "failed", "message": "bluetooth state \(central.state.rawValue)"])
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    var name = peripheral.name ?? ""
    if let adv = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !adv.isEmpty {
      name = adv
    }
    if !name.hasPrefix("XuPlay-Setup-") { return }
    found[name] = peripheral
    rssi[name] = RSSI.intValue
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.delegate = self
    peripheral.discoverServices([serviceUUID])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    report(["action": "write", "state": "failed", "message": error?.localizedDescription ?? "connect failed"])
  }
}

extension ProvisionManager: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      report(["action": "write", "state": "failed", "message": error.localizedDescription])
      return
    }
    guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
      report(["action": "write", "state": "failed", "message": "provisioning service not found"])
      return
    }
    peripheral.discoverCharacteristics([configUUID, statusUUID], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if let error {
      report(["action": "write", "state": "failed", "message": error.localizedDescription])
      return
    }
    for c in service.characteristics ?? [] {
      if c.uuid == configUUID { configChar = c }
      if c.uuid == statusUUID {
        statusChar = c
        peripheral.setNotifyValue(true, for: c)
      }
    }
    guard let cfg = configChar, let data = pendingConfig else {
      report(["action": "write", "state": "failed", "message": "config characteristic not found"])
      return
    }
    let type: CBCharacteristicWriteType = cfg.properties.contains(.write) ? .withResponse : .withoutResponse
    peripheral.writeValue(data, for: cfg, type: type)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error {
      report(["action": "write", "state": "failed", "message": error.localizedDescription])
      return
    }
    report(["action": "write", "state": "sent", "message": "configuration written"])
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard characteristic.uuid == statusUUID, let data = characteristic.value,
          let text = String(data: data, encoding: .utf8) else { return }
    report(["action": "write", "state": "status", "message": text])
  }
}

// MARK: - XuESP Console View

private struct HardwareKeySpec {
  let title: String
  let op: String
  let key: String
}

final class XuEspConsoleView: NSView {
  var wsPort: UInt16 = 8765

  private let topBar = NSView()
  private let brandLabel = NSTextField(labelWithString: "XuESP 控制器")
  private let statusSummaryLabel = NSTextField(labelWithString: "MQTT 监听中")
  private let provisionBtn = NSButton(title: "蓝牙配网新 ESP32", target: nil, action: nil)
  private let stopAllBtn = NSButton(title: "■ 急停", target: nil, action: nil)

  private let fixedKeyBar = NSView()
  private let fixedKeyTitle = NSTextField(labelWithString: "快捷按键")
  private var fixedKeyButtons: [NSButton] = []

  private let commandBar = NSView()
  private var deviceChipButtons: [NSButton] = []
  private let commandField = NSTextField()
  private let runOneBtn = NSButton(title: "单机执行", target: nil, action: nil)
  private let runAllBtn = NSButton(title: "全集群群发", target: nil, action: nil)
  private let saveTraceBtn = NSButton(title: "保存轨迹为宏", target: nil, action: nil)
  private let clearTraceBtn = NSButton(title: "清空轨迹", target: nil, action: nil)
  private var macroButtons: [NSButton] = []

  private let bodyView = NSView()
  private let clusterTitle = NSTextField(labelWithString: "ESP32 节点与 BLE 槽位 · 配网 · MCP")
  private let clusterScroll = NSScrollView()
  private let clusterTextView = NSTextView()
  private let macroTitle = NSTextField(labelWithString: "操作宏库")
  private let macroScroll = NSScrollView()
  private let macroTextView = NSTextView()
  private let logTitle = NSTextField(labelWithString: "执行日志")
  private let logScroll = NSScrollView()
  private let logTextView = NSTextView()

  private var devices: [EspTargetDevice] = []
  private var selectedIds: Set<String> = []
  private var activeDeviceId: String = ""
  private var espNodes: [[String: Any]] = []
  private var macroDefs: [[String: Any]] = []
  private let cmdQueue = DispatchQueue(label: "xuesp.console.cmd")

  private struct MacroSpec {
    let title: String
    let macro: String
    let takesArgument: Bool
  }

  private let macroSpecs: [MacroSpec] = [
    MacroSpec(title: "打开网址", macro: "open_url", takesArgument: true),
    MacroSpec(title: "打开 App", macro: "open_app", takesArgument: true),
    MacroSpec(title: "搜索", macro: "spotlight_search", takesArgument: true),
    MacroSpec(title: "清空并输入", macro: "clear_and_submit", takesArgument: true),
    MacroSpec(title: "解锁", macro: "unlock_screen", takesArgument: false),
    MacroSpec(title: "多任务", macro: "app_switcher", takesArgument: false),
    MacroSpec(title: "关闭 App", macro: "kill_current_app", takesArgument: false),
    MacroSpec(title: "刷新页面", macro: "refresh_page", takesArgument: false)
  ]

  private static let fixedKeySpecs: [HardwareKeySpec] = [
    HardwareKeySpec(title: "主屏幕", op: "home", key: ""),
    HardwareKeySpec(title: "返回", op: "back", key: ""),
    HardwareKeySpec(title: "搜索", op: "shortcut", key: "cmd_space"),
    HardwareKeySpec(title: "地址栏", op: "shortcut", key: "cmd_l"),
    HardwareKeySpec(title: "新标签", op: "shortcut", key: "cmd_t"),
    HardwareKeySpec(title: "复制", op: "shortcut", key: "cmd_c"),
    HardwareKeySpec(title: "粘贴", op: "shortcut", key: "cmd_v"),
    HardwareKeySpec(title: "回车", op: "key", key: "enter"),
    HardwareKeySpec(title: "音量 +", op: "consumer", key: "vol_up"),
    HardwareKeySpec(title: "音量 −", op: "consumer", key: "vol_down"),
    HardwareKeySpec(title: "静音", op: "consumer", key: "mute"),
    HardwareKeySpec(title: "锁屏", op: "consumer", key: "power")
  ]

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = EspTheme.canvasBg.cgColor
    setupTopBar()
    setupFixedKeyBar()
    setupCommandBar()
    setupBody()
    renderCluster()
    renderMacros()
  }

  required init?(coder: NSCoder) { nil }

  private func setupTopBar() {
    topBar.wantsLayer = true
    topBar.layer?.backgroundColor = EspTheme.panelBg.cgColor
    addSubview(topBar)

    brandLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    brandLabel.textColor = EspTheme.textPrimary
    topBar.addSubview(brandLabel)

    statusSummaryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    statusSummaryLabel.textColor = EspTheme.textSecondary
    topBar.addSubview(statusSummaryLabel)

    provisionBtn.bezelStyle = .rounded
    provisionBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    provisionBtn.target = self
    provisionBtn.action = #selector(provisionClicked)
    topBar.addSubview(provisionBtn)

    stopAllBtn.bezelStyle = .rounded
    stopAllBtn.contentTintColor = EspTheme.danger
    stopAllBtn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    stopAllBtn.target = self
    stopAllBtn.action = #selector(stopAllClicked)
    topBar.addSubview(stopAllBtn)
  }

  private func setupFixedKeyBar() {
    fixedKeyBar.wantsLayer = true
    fixedKeyBar.layer?.backgroundColor = EspTheme.elevatedBg.cgColor
    fixedKeyBar.layer?.borderWidth = 1
    fixedKeyBar.layer?.borderColor = EspTheme.border.cgColor
    addSubview(fixedKeyBar)

    fixedKeyTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    fixedKeyTitle.textColor = EspTheme.textSecondary
    fixedKeyBar.addSubview(fixedKeyTitle)

    for (idx, spec) in Self.fixedKeySpecs.enumerated() {
      let b = NSButton(title: spec.title, target: self, action: #selector(fixedKeyClicked(_:)))
      b.tag = idx
      b.bezelStyle = .inline
      b.font = NSFont.systemFont(ofSize: 11, weight: .medium)
      b.toolTip = spec.op + (spec.key.isEmpty ? "" : " " + spec.key)
      fixedKeyBar.addSubview(b)
      fixedKeyButtons.append(b)
    }
    updateKeyEnabled()
  }

  private func setupCommandBar() {
    commandBar.wantsLayer = true
    commandBar.layer?.backgroundColor = EspTheme.elevatedBg.cgColor
    commandBar.layer?.borderWidth = 1
    commandBar.layer?.borderColor = EspTheme.border.cgColor
    addSubview(commandBar)

    commandField.placeholderString = "命令或流水线：tap 16384 16384 && wait 300 && submit hello"
    commandField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    commandField.target = self
    commandField.action = #selector(runOneClicked)
    commandBar.addSubview(commandField)

    runOneBtn.bezelStyle = .rounded
    runOneBtn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    runOneBtn.target = self
    runOneBtn.action = #selector(runOneClicked)
    commandBar.addSubview(runOneBtn)

    runAllBtn.bezelStyle = .rounded
    runAllBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    runAllBtn.target = self
    runAllBtn.action = #selector(runAllClicked)
    commandBar.addSubview(runAllBtn)

    for (idx, spec) in macroSpecs.enumerated() {
      let b = NSButton(title: spec.title, target: self, action: #selector(macroButtonClicked(_:)))
      b.tag = idx
      b.bezelStyle = .inline
      b.font = NSFont.systemFont(ofSize: 11, weight: .medium)
      b.toolTip = spec.takesArgument ? "macro:\(spec.macro) <命令行内容>" : "macro:\(spec.macro)"
      commandBar.addSubview(b)
      macroButtons.append(b)
    }

    saveTraceBtn.bezelStyle = .rounded
    saveTraceBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    saveTraceBtn.target = self
    saveTraceBtn.action = #selector(saveTraceClicked)
    commandBar.addSubview(saveTraceBtn)

    clearTraceBtn.bezelStyle = .rounded
    clearTraceBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    clearTraceBtn.target = self
    clearTraceBtn.action = #selector(clearTraceClicked)
    commandBar.addSubview(clearTraceBtn)
  }

  private func setupBody() {
    bodyView.wantsLayer = true
    bodyView.layer?.backgroundColor = EspTheme.panelBg.cgColor
    addSubview(bodyView)

    for t in [clusterTitle, macroTitle, logTitle] {
      t.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
      t.textColor = EspTheme.textSecondary
      bodyView.addSubview(t)
    }

    clusterScroll.hasVerticalScroller = true
    clusterScroll.borderType = .lineBorder
    styleTextView(clusterTextView)
    clusterTextView.string = "等待集群状态…"
    clusterScroll.documentView = clusterTextView
    bodyView.addSubview(clusterScroll)

    macroScroll.hasVerticalScroller = true
    macroScroll.borderType = .lineBorder
    styleTextView(macroTextView)
    macroScroll.documentView = macroTextView
    bodyView.addSubview(macroScroll)

    logScroll.hasVerticalScroller = true
    logScroll.borderType = .lineBorder
    styleTextView(logTextView)
    logTextView.string = "XuESP 控制器已就绪（与 XuPlay 展示端完全解耦）。\n"
    logScroll.documentView = logTextView
    bodyView.addSubview(logScroll)
  }

  private func styleTextView(_ tv: NSTextView) {
    tv.isEditable = false
    tv.isRichText = false
    tv.backgroundColor = EspTheme.canvasBg
    tv.textColor = EspTheme.textPrimary
    tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    tv.textContainerInset = NSSize(width: 6, height: 6)
  }

  override func layout() {
    super.layout()
    let w = bounds.width
    let h = bounds.height
    let topH: CGFloat = 42
    let fixedH: CGFloat = 32
    let cmdH: CGFloat = 88
    let bodyH = max(120, h - topH - fixedH - cmdH)

    topBar.frame = NSRect(x: 0, y: h - topH, width: w, height: topH)
    brandLabel.frame = NSRect(x: 16, y: 11, width: 120, height: 20)
    stopAllBtn.frame = NSRect(x: w - 104, y: 7, width: 90, height: 28)
    provisionBtn.frame = NSRect(x: w - 232, y: 8, width: 120, height: 26)
    statusSummaryLabel.frame = NSRect(x: 140, y: 13, width: max(100, w - 384), height: 16)

    fixedKeyBar.frame = NSRect(x: 0, y: h - topH - fixedH, width: w, height: fixedH)
    layoutFixedKeyBar()

    bodyView.frame = NSRect(x: 0, y: cmdH, width: w, height: bodyH)
    layoutBody(width: w, height: bodyH)

    commandBar.frame = NSRect(x: 0, y: 0, width: w, height: cmdH)
    layoutDeviceChips()
    layoutCommandBar()
  }

  private func layoutFixedKeyBar() {
    fixedKeyTitle.frame = NSRect(x: 12, y: 7, width: 56, height: 16)
    var x: CGFloat = 72
    for b in fixedKeyButtons {
      let bw = CGFloat(b.title.count * 13 + 14)
      b.frame = NSRect(x: x, y: 4, width: bw, height: 22)
      x += bw + 4
    }
  }

  private func layoutBody(width w: CGFloat, height h: CGFloat) {
    let clusterH: CGFloat = max(110, floor(h * 0.40))
    let macroH: CGFloat = max(80, floor(h * 0.26))
    let logH: CGFloat = max(80, h - clusterH - macroH - 68)

    clusterTitle.frame = NSRect(x: 12, y: h - 20, width: w - 24, height: 16)
    clusterScroll.frame = NSRect(x: 12, y: h - 22 - clusterH, width: w - 24, height: clusterH)
    clusterTextView.frame = NSRect(x: 0, y: 0, width: w - 40, height: clusterH)

    macroTitle.frame = NSRect(x: 12, y: h - 40 - clusterH, width: w - 24, height: 16)
    macroScroll.frame = NSRect(x: 12, y: h - 42 - clusterH - macroH, width: w - 24, height: macroH)
    macroTextView.frame = NSRect(x: 0, y: 0, width: w - 40, height: macroH)

    logTitle.frame = NSRect(x: 12, y: h - 60 - clusterH - macroH, width: w - 24, height: 16)
    logScroll.frame = NSRect(x: 12, y: 8, width: w - 24, height: logH)
    logTextView.frame = NSRect(x: 0, y: 0, width: w - 40, height: logH)
  }

  private func layoutDeviceChips() {
    deviceChipButtons.forEach { $0.removeFromSuperview() }
    deviceChipButtons.removeAll()

    let allBtn = NSButton(title: "全选 (\(devices.count))", target: self, action: #selector(selectAllDevices))
    allBtn.bezelStyle = .inline
    allBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    commandBar.addSubview(allBtn)
    deviceChipButtons.append(allBtn)

    for (idx, d) in devices.enumerated() {
      let isActive = (d.id == activeDeviceId)
      let on = selectedIds.contains(d.id)
      let mark = isActive ? "● " : (on ? "✓ " : "")
      let label = d.phoneName.isEmpty ? d.id : "\(d.phoneName)(\(d.id))"
      let b = NSButton(title: "\(mark)\(label)", target: self, action: #selector(chipButtonClicked(_:)))
      b.tag = idx
      b.bezelStyle = .inline
      b.contentTintColor = isActive ? EspTheme.accentBlue : EspTheme.textPrimary
      b.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: isActive ? .bold : (on ? .semibold : .regular))
      commandBar.addSubview(b)
      deviceChipButtons.append(b)
    }
  }

  private func layoutCommandBar() {
    let cw = commandBar.bounds.width
    var x: CGFloat = 12
    for b in deviceChipButtons {
      let bw = min(130, max(66, CGFloat(b.title.count * 8 + 22)))
      b.frame = NSRect(x: x, y: 58, width: bw, height: 22)
      x += bw + 5
    }
    runOneBtn.frame = NSRect(x: cw - 200, y: 57, width: 90, height: 26)
    runAllBtn.frame = NSRect(x: cw - 104, y: 57, width: 92, height: 26)
    commandField.frame = NSRect(x: max(x + 6, 120), y: 58, width: max(120, cw - max(x + 6, 120) - 208), height: 24)

    var mx: CGFloat = 12
    for b in macroButtons {
      let bw = CGFloat(b.title.count * 13 + 14)
      b.frame = NSRect(x: mx, y: 26, width: bw, height: 22)
      mx += bw + 4
    }
    saveTraceBtn.frame = NSRect(x: cw - 200, y: 24, width: 96, height: 24)
    clearTraceBtn.frame = NSRect(x: cw - 100, y: 24, width: 88, height: 24)
  }

  private func updateKeyEnabled() {
    let active = devices.first { $0.id == activeDeviceId }
    let ready = !activeDeviceId.isEmpty && (active?.bleSlot ?? -1) >= 0
    for b in fixedKeyButtons { b.isEnabled = ready }
  }

  @objc private func selectAllDevices() {
    if selectedIds.count == devices.count {
      selectedIds.removeAll()
    } else {
      selectedIds = Set(devices.map { $0.id })
    }
    layoutDeviceChips()
    layoutCommandBar()
  }

  @objc private func chipButtonClicked(_ sender: NSButton) {
    let idx = sender.tag
    guard idx >= 0, idx < devices.count else { return }
    let targetId = devices[idx].id
    if NSEvent.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.command) {
      if selectedIds.contains(targetId) { selectedIds.remove(targetId) } else { selectedIds.insert(targetId) }
    } else {
      selectedIds.insert(targetId)
      activeDeviceId = targetId
    }
    updateKeyEnabled()
    layoutDeviceChips()
    layoutCommandBar()
  }

  @objc private func fixedKeyClicked(_ sender: NSButton) {
    let idx = sender.tag
    guard idx >= 0, idx < Self.fixedKeySpecs.count else { return }
    guard !activeDeviceId.isEmpty else { return }
    let spec = Self.fixedKeySpecs[idx]
    var payload: [String: Any] = ["op": spec.op, "device": activeDeviceId]
    if !spec.key.isEmpty { payload["key"] = spec.key }
    sendCommand(payload)
  }

  @objc private func macroButtonClicked(_ sender: NSButton) {
    let idx = sender.tag
    guard idx >= 0, idx < macroSpecs.count else { return }
    let spec = macroSpecs[idx]
    let arg = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if spec.takesArgument && arg.isEmpty {
      logTextView.string = "宏 \(spec.macro) 需要参数：先在命令行输入内容。\n" + logTextView.string
      return
    }
    let cmd = spec.takesArgument ? "macro:\(spec.macro) \(arg)" : "macro:\(spec.macro)"
    guard !activeDeviceId.isEmpty else { return }
    sendCommand(["op": "exec", "device": activeDeviceId, "text": cmd])
  }

  @objc private func runOneClicked() {
    let trimmed = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !activeDeviceId.isEmpty else { return }
    sendCommand(["op": "exec", "device": activeDeviceId, "text": trimmed])
  }

  @objc private func runAllClicked() {
    let cmd = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cmd.isEmpty else { return }
    let picked = devices.filter { selectedIds.contains($0.id) }.map { $0.id }
    let targets = picked.isEmpty ? devices.map { $0.id } : picked
    sendCommand(["op": "batch", "mode": "broadcast", "devices": targets, "text": cmd])
  }

  @objc private func saveTraceClicked() {
    let name = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      logTextView.string = "保存宏需要名称：先在命令行输入宏名。\n" + logTextView.string
      return
    }
    sendCommand(["op": "trace_to_macro", "name": name, "title": name, "desc": "由操作轨迹生成"])
  }

  @objc private func clearTraceClicked() {
    sendCommand(["op": "trace_clear"])
  }

  @objc private func stopAllClicked() {
    sendCommand(["op": "stop"])
  }

  @objc private func provisionClicked() {
    sendCommand(["op": "provision_scan"])
  }

  func sendCommand(_ payload: [String: Any], callback: (([String: Any]) -> Void)? = nil) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let str = String(data: data, encoding: .utf8) else { return }
    let port = wsPort
    cmdQueue.async { [weak self] in
      guard let resp = LoopbackWSClient.request(port: port, jsonString: str, timeoutMs: 12000) else { return }
      let stateResp = LoopbackWSClient.request(port: port, jsonString: "{\"op\":\"cluster_state\"}", timeoutMs: 3000)
      DispatchQueue.main.async {
        if let stateResp { self?.applyClusterState(stateResp) }
        callback?(resp)
      }
    }
  }

  func applyClusterState(_ dict: [String: Any]) {
    var parsed: [EspTargetDevice] = []
    if let arr = dict["devices"] as? [[String: Any]] {
      for item in arr {
        parsed.append(EspTargetDevice(
          id: item["id"] as? String ?? "",
          phoneName: item["phone_name"] as? String ?? "",
          mqttTopic: item["mqtt_topic"] as? String ?? "xu/esp32/cyd",
          bleSlot: item["ble_slot"] as? Int ?? -1,
          blePeer: item["ble_peer"] as? String ?? "",
          group: item["group"] as? String ?? "default"
        ))
      }
    }
    let wasEmpty = devices.isEmpty
    devices = parsed
    if !devices.contains(where: { $0.id == activeDeviceId }) {
      activeDeviceId = devices.first?.id ?? ""
    }
    if wasEmpty && !devices.isEmpty {
      selectedIds = Set(devices.map { $0.id })
    }
    if let nodes = dict["esp_nodes"] as? [[String: Any]] {
      espNodes = nodes
    }
    if let macros = dict["macros"] as? [[String: Any]] {
      macroDefs = macros
    }
    updateKeyEnabled()
    layoutDeviceChips()
    layoutCommandBar()
    renderCluster()
    renderMacros()

    let peersCount = (dict["ble_peers"] as? [[String: Any]])?.count ?? 0
    let nodesCount = espNodes.filter { ($0["online"] as? Bool) ?? false }.count
    statusSummaryLabel.stringValue =
      "ESP32 节点 \(nodesCount) · BLE 设备 \(peersCount)/\(nodesCount * 4) · 活动目标 \(activeDeviceId.isEmpty ? "无" : activeDeviceId) · ws:\(wsPort)"

    if let logs = dict["logs"] as? [String], !logs.isEmpty {
      let joined = logs.joined(separator: "\n")
      if logTextView.string != joined {
        logTextView.string = joined
        logTextView.scrollToEndOfDocument(nil)
      }
    }
  }

  private func renderCluster() {
    var lines: [String] = []
    if espNodes.isEmpty {
      lines.append("未发现 ESP32 节点。检查 MQTT 连接与节点主题 xu/esp32/<node>/status。")
    }
    for node in espNodes {
      let topic = node["mqtt_topic"] as? String ?? ""
      let online = node["online"] as? Bool ?? false
      let adv = node["advertising"] as? Bool ?? false
      let cc = node["connected_count"] as? Int ?? 0
      let dot = online ? "●" : "○"
      let advText = adv ? "开" : "关"
      lines.append("\(dot) \(topic)   已连接 \(cc)   广播 \(advText)")
      if let peers = node["peers"] as? [[String: Any]] {
        for p in peers {
          let slot = p["slot"] as? Int ?? 0
          let ready = p["ready"] as? Bool ?? false
          let name = p["name"] as? String ?? ""
          let bda = p["bda"] as? String ?? ""
          let tick = ready ? "✓" : "·"
          let who = name.isEmpty ? "-" : name
          lines.append("    slot \(slot)  \(tick)  \(who)  \(bda)")
        }
      }
    }
    lines.append("")
    lines.append("MCP 接入：stdio `xuesp mcp`  ·  HTTP POST :8766/mcp  ·  控制面 ws://127.0.0.1:\(wsPort)")
    lines.append("蓝牙配网：ESP32 未联网时广播 XuPlay-Setup-XXXX，点顶部 [蓝牙配网新 ESP32] 配 Wi-Fi 与 MQTT。")
    clusterTextView.string = lines.joined(separator: "\n")
  }

  private func renderMacros() {
    var lines: [String] = []
    for m in macroDefs {
      let name = m["name"] as? String ?? ""
      let title = m["title"] as? String ?? ""
      let builtin = m["builtin"] as? Bool ?? false
      let params = m["params"] as? String ?? ""
      let suffix = params.isEmpty ? "" : " <\(params)>"
      let mark = builtin ? "·" : "*"
      lines.append("\(mark) \(name)\(suffix)  \(title)")
    }
    macroTextView.string = lines.isEmpty ? "暂无宏。" : lines.joined(separator: "\n")
  }
}

// MARK: - XuESP Content Plugin

final class XuEspPlugin: NSObject, XuContentPlugin {
  weak var shell: AppDelegate?
  var consoleView: XuEspConsoleView?
  var running = false
  var wantsDevToolsMenu: Bool { false }
  private var wsPort: UInt16 = 8765
  private var handledProvisionJobID = ""

  init(shell: AppDelegate) {
    self.shell = shell
    super.init()
  }

  func install(into root: NSView, host: AppDelegate) {
    shell = host
    let console = XuEspConsoleView(frame: root.bounds)
    console.autoresizingMask = [.width, .height]
    root.addSubview(console)
    consoleView = console
    running = true

    Thread.detachNewThread { [weak self, weak host] in
      var wsPort: UInt16 = 8765
      for _ in 0..<25 {
        let rawWs = DispatchQueue.main.sync { host?.readTrimmed("xu_ui_xuesp_ws.txt") ?? "" }
        if let p = UInt16(rawWs), p > 0 {
          wsPort = p
          break
        }
        usleep(80_000)
      }
      DispatchQueue.main.async {
        self?.consoleView?.wsPort = wsPort
        self?.wsPort = wsPort
      }
      while self?.running == true {
        if let resp = LoopbackWSClient.request(port: wsPort, jsonString: "{\"op\":\"cluster_state\"}", timeoutMs: 2500) {
          DispatchQueue.main.async {
            self?.consoleView?.applyClusterState(resp)
          }
          self?.handleProvisionJobIfNeeded(resp)
        }
        usleep(1_000_000)
      }
    }
  }

  private func handleProvisionJobIfNeeded(_ state: [String: Any]) {
    guard let job = state["provision_job"] as? String, !job.isEmpty else { return }
    guard let data = job.data(using: .utf8),
          let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    let jobID = parsed["id"] as? String ?? ""
    if jobID.isEmpty || jobID == handledProvisionJobID { return }
    handledProvisionJobID = jobID

    let port = wsPort
    let post: (String) -> Void = { text in
      var body: [String: Any] = [:]
      if let data = text.data(using: .utf8),
         let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        body = parsed
      }
      body["id"] = jobID
      guard let out = (try? JSONSerialization.data(withJSONObject: body)),
            let json = String(data: out, encoding: .utf8) else { return }
      _ = LoopbackWSClient.request(port: port, jsonString: json, timeoutMs: 4000)
    }
    let action = parsed["action"] as? String ?? "scan"
    if action == "write" {
      var config: [String: String] = [:]
      config["ssid"] = parsed["ssid"] as? String ?? ""
      config["pass"] = parsed["pass"] as? String ?? ""
      config["mqtt_uri"] = parsed["mqtt_uri"] as? String ?? ""
      config["root"] = parsed["root"] as? String ?? ""
      config["name"] = parsed["name"] as? String ?? ""
      ProvisionManager.shared.write(device: parsed["device"] as? String ?? "", config: config, onResult: post)
    } else {
      ProvisionManager.shared.scan(onResult: post)
    }
  }

  func handleCmd(_ s: String) -> Bool { false }
  func onPoll() {}
  func syncFrame() {}
  func evalJS(_ js: String) {}
  func snapshotPNG(to path: String, completion: @escaping (Bool) -> Void) { completion(false) }
  func snapshotClipboard(completion: @escaping (Bool) -> Void) { completion(false) }
  func onFilesDropped(_ paths: [String]) {}

  func shutdown() {
    running = false
    consoleView?.removeFromSuperview()
    consoleView = nil
  }
}

@objc(XuEspBootstrap)
public class XuEspBootstrap: NSObject {
  @objc public static func registerPlugin() {
    Darwin.signal(SIGPIPE, SIG_IGN)
    XuContentRegistry.make = { host in XuEspPlugin(shell: host) }
  }
}
