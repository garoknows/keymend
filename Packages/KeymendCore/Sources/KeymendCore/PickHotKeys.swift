import Carbon.HIToolbox
import Foundation

/// Registers and removes system hot keys. Tests use a stand-in.
public protocol HotKeyRegistering: AnyObject, Sendable {
    /// Returns false if macOS refused the key.
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool
    func unregisterAll()
}

extension PickModifier {
    /// The same modifiers in the form Carbon hot keys use.
    public var carbonFlags: UInt32 {
        switch self {
        case .option: return UInt32(optionKey)
        case .controlOption: return UInt32(controlKey | optionKey)
        case .optionShift: return UInt32(optionKey | shiftKey)
        }
    }
}

/// The pick keys as system hot keys, registered only while the bar shows.
///
/// Why not an event tap: beta.2 used an active event tap to stop the pick keys reaching the app,
/// and switching off Accessibility while it ran froze a real Mac's keyboard and mouse until a
/// forced restart. A hot key is how Keymend's Control-Option-K pause shortcut already works:
/// macOS hands the key to Keymend instead of the app, needs no permission for it, and nothing of
/// Keymend's sits in the path every key and click takes. So there's nothing left to freeze.
public final class HotKeyPickBackend: PickTapBackend, @unchecked Sendable {
    /// Hot key IDs for slots 0 to 3. ID 1 is the pause shortcut.
    public static let firstID: UInt32 = 100

    private let registrar: HotKeyRegistering
    private let modifier: @Sendable () -> PickModifier

    public init(registrar: HotKeyRegistering, modifier: @escaping @Sendable () -> PickModifier) {
        self.registrar = registrar
        self.modifier = modifier
    }

    /// Registers all four pick keys, or none.
    public func start() -> Bool {
        let flags = modifier().carbonFlags
        for (slot, key) in PickKeys.numberRow.enumerated() {
            guard registrar.register(keyCode: UInt32(key), modifiers: flags, id: Self.firstID + UInt32(slot)) else {
                registrar.unregisterAll()
                return false
            }
        }
        return true
    }

    public func stop() {
        registrar.unregisterAll()
    }

    /// The slot a hot key picks, or nil if it isn't a pick key.
    public static func slot(forHotKeyID id: UInt32) -> Int? {
        guard id >= firstID, id < firstID + UInt32(PickKeys.numberRow.count) else { return nil }
        return Int(id - firstID)
    }
}

/// The real hot keys. Carbon wants these calls on the main thread: from anywhere else they're
/// sent there, and a removal that was overtaken by a newer registration is skipped.
public final class CarbonHotKeys: HotKeyRegistering, @unchecked Sendable {
    /// "KMPK". The pause shortcut uses "KMND".
    public static let signature: OSType = 0x4B4D_504B

    private let lock = NSLock()
    /// Main thread only.
    private var refs: [EventHotKeyRef] = []
    /// Goes up with every registration. Guarded by `lock`.
    private var generation: UInt64 = 0

    public init() {}

    public func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        lock.withLock { generation &+= 1 }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { _ = self.registerNow(keyCode: keyCode, modifiers: modifiers, id: id) }
            return true
        }
        return registerNow(keyCode: keyCode, modifiers: modifiers, id: id)
    }

    public func unregisterAll() {
        guard !Thread.isMainThread else { return removeNow() }
        let seen = lock.withLock { generation }
        DispatchQueue.main.async {
            guard self.lock.withLock({ self.generation }) == seen else { return }
            self.removeNow()
        }
    }

    private func registerNow(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return false }
        refs.append(ref)
        return true
    }

    private func removeNow() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }
}
