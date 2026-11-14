import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 红绿灯在侧栏里水平居中（侧栏宽 84，三个按钮连同间距约 54），
  /// 垂直方向与 56 高的顶栏中线对齐（见 lib/shell.dart 的 _Rail 与 _TopBar）
  private let trafficLightsLeft: CGFloat = 15
  private let trafficLightsCenterY: CGFloat = 28

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 启动器自己绘制标题栏，使用系统原生的红绿灯按钮（保留悬停菜单、全屏、分屏等系统功能），
    // 只是把它们挪到侧栏里，和微信等应用一样
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    // 系统在窗口缩放、进出全屏、切换焦点时会把按钮放回默认位置，每次都重新摆一次
    let center = NotificationCenter.default
    for name in [
      NSWindow.didResizeNotification,
      NSWindow.didEndLiveResizeNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didChangeBackingPropertiesNotification,
    ] {
      center.addObserver(self, selector: #selector(trafficLightsNeedLayout), name: name, object: self)
    }

    super.awakeFromNib()
    layoutTrafficLights()
  }

  @objc private func trafficLightsNeedLayout() {
    layoutTrafficLights()
    // 系统可能在通知之后才完成自己的布局，下一轮再摆一次
    DispatchQueue.main.async { [weak self] in self?.layoutTrafficLights() }
  }

  /// 做法同 Electron 的 trafficLightPosition：加高按钮所在的标题栏容器，再逐个设置按钮位置
  private func layoutTrafficLights() {
    // 全屏时标题栏由系统管理
    if styleMask.contains(.fullScreen) { return }
    guard
      let close = standardWindowButton(.closeButton),
      let miniaturize = standardWindowButton(.miniaturizeButton),
      let zoom = standardWindowButton(.zoomButton),
      let container = close.superview?.superview
    else { return }

    let buttonHeight = close.frame.height
    let containerHeight = trafficLightsCenterY * 2
    var rect = container.frame
    rect.size.height = containerHeight
    rect.origin.y = frame.height - containerHeight
    container.frame = rect

    let spacing = miniaturize.frame.origin.x - close.frame.origin.x
    for (i, button) in [close, miniaturize, zoom].enumerated() {
      button.setFrameOrigin(
        NSPoint(x: trafficLightsLeft + CGFloat(i) * spacing, y: (containerHeight - buttonHeight) / 2))
    }
  }
}
