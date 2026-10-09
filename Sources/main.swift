import AppKit
import Carbon
import ServiceManagement

// MARK: - Keyboard layout

struct Key {
    let code: UInt16
    let shift: Bool
    let caps: Bool
}

final class Layout {
    let source: TISInputSource
    let id: String
    let lang: String
    private let data: Data

    init?(_ source: TISInputSource) {
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        self.source = source
        id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        var langs: [String] = []
        if let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            langs = (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
        }
        if langs.contains("uk") { lang = "uk" }
        else if langs.contains("en") { lang = "en" }
        else { lang = String((langs.first ?? "en").prefix(2)) }
    }

    func translate(_ keys: [Key]) -> String {
        var out = ""
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for k in keys {
                var dead: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let mods = UInt32((k.shift ? shiftKey : 0) | (k.caps ? alphaLock : 0)) >> 8
                UCKeyTranslate(layout, k.code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                out += String(utf16CodeUnits: chars, count: len)
            }
        }
        return out
    }
}

func sourceID(_ s: TISInputSource) -> String? {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

// MARK: - Engine

final class Engine {
    var layouts: [Layout] = []
    var tap: CFMachPort?

    // Current word (keys typed since the last boundary).
    var buffer: [Key] = []
    var wordConverted = false
    var wordAuto = false
    // Previous word, while the cursor is right after its trailing space.
    var lastWord: [Key]?
    var lastWordAuto = false

    var expectedSourceID: String?
    var frontApp: String?

    var shiftDownAt: TimeInterval = 0
    var shiftClean = false
    var lastShiftTap: TimeInterval = 0

    let spell = NSSpellChecker.shared
    let marker: Int64 = 0x4C53_5754
    let eventSource = CGEventSource(stateID: .privateState)
    let defaults = UserDefaults.standard

    var autoEnabled: Bool {
        get { defaults.object(forKey: "autoEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoEnabled") }
    }
    var excluded: Set<String> {
        get { Set(defaults.stringArray(forKey: "excluded") ?? Engine.defaultExcluded) }
        set { defaults.set(Array(newValue), forKey: "excluded") }
    }
    var ignored: Set<String> {
        get { Set(defaults.stringArray(forKey: "ignored") ?? []) }
        set { defaults.set(Array(newValue), forKey: "ignored") }
    }

    static let defaultExcluded = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
    ]

    init() {
        reloadLayouts()
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func reloadLayouts() {
        let props = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        let list = (TISCreateInputSourceList(props, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        layouts = list.compactMap(Layout.init)
    }

    func currentLayout() -> Layout? {
        let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let id = sourceID(src)
        return layouts.first { $0.id == id }
    }

    func other(than cur: Layout) -> Layout? {
        let rest = layouts.filter { $0.id != cur.id }
        if rest.count <= 1 { return rest.first }
        let want = cur.lang == "uk" ? "en" : "uk"
        return rest.first { $0.lang == want } ?? rest.first
    }

    func isExcluded() -> Bool {
        guard let app = frontApp else { return false }
        return excluded.contains(app) || app.hasPrefix("com.jetbrains.")
    }

    func resetWord() {
        buffer = []
        wordConverted = false
        wordAuto = false
    }

    func resetAll() {
        resetWord()
        lastWord = nil
        lastWordAuto = false
    }

    // MARK: Event handling

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            resetAll()
            return pass
        case .flagsChanged:
            handleFlags(event)
            return pass
        case .keyDown:
            break
        default:
            return pass
        }

        if event.getIntegerValueField(.eventSourceUserData) == marker { return pass }
        shiftClean = false
        lastShiftTap = 0

        guard !isExcluded() else { resetAll(); return pass }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            resetAll()
            return pass
        }

        switch code {
        case 51: // backspace
            if buffer.isEmpty { lastWord = nil } else { buffer.removeLast() }
            if buffer.isEmpty { wordConverted = false; wordAuto = false }
            return pass
        case 49: // space
            return onSpace(event)
        case 36, 48, 76, 53, 117, 115, 119, 116, 121, 123, 124, 125, 126:
            resetAll()
            return pass
        default:
            break
        }

        guard let cur = currentLayout() else { resetAll(); return pass }
        let key = Key(code: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
        guard let s = cur.translate([key]).unicodeScalars.first, s.value >= 0x20, s.value != 0x7F else {
            resetAll()
            return pass
        }

        buffer.append(key)
        lastWord = nil

        if autoEnabled, !wordConverted, (4...7).contains(buffer.count),
           let alt = other(than: cur), shouldConvertPrefix(buffer, from: cur, to: alt) {
            // Current key not delivered yet: only count-1 chars are on screen.
            replace(deleting: buffer.count - 1, with: alt.translate(buffer), switchTo: alt)
            wordConverted = true
            wordAuto = true
            return nil
        }
        return pass
    }

    func onSpace(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard !buffer.isEmpty, let cur = currentLayout() else {
            resetAll()
            return pass
        }
        let keys = buffer
        let check = autoEnabled && !wordConverted
        let wasAuto = wordAuto
        resetWord()

        if check, let alt = other(than: cur),
           keys.count >= 3 ? shouldConvertWord(keys, from: cur, to: alt) : shouldConvertShort(keys, from: cur, to: alt) {
            replace(deleting: keys.count, with: alt.translate(keys) + " ", switchTo: alt)
            lastWord = keys
            lastWordAuto = true
            return nil
        }
        lastWord = keys
        lastWordAuto = wasAuto
        return pass
    }

    func handleFlags(_ e: CGEvent) {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime
        guard code == 56 || code == 60 else {
            shiftClean = false
            lastShiftTap = 0
            return
        }
        if e.flags.contains(.maskShift) {
            shiftDownAt = now
            shiftClean = true
            return
        }
        guard shiftClean, now - shiftDownAt < 0.3 else { return }
        shiftClean = false
        if now - lastShiftTap < 0.45 {
            lastShiftTap = 0
            manualConvert()
        } else {
            lastShiftTap = now
        }
    }

    // Double Shift: convert the current/last word, or just toggle the layout.
    func manualConvert() {
        guard let cur = currentLayout(), let alt = other(than: cur) else { return }
        if isExcluded() {
            select(alt)
            return
        }
        if !buffer.isEmpty {
            if wordAuto { learn(alt.translate(buffer)) }
            replace(deleting: buffer.count, with: alt.translate(buffer), switchTo: alt)
            wordConverted = true
            wordAuto = false
        } else if let keys = lastWord {
            if lastWordAuto { learn(alt.translate(keys)) }
            lastWordAuto = false
            replace(deleting: keys.count + 1, with: alt.translate(keys) + " ", switchTo: alt)
        } else {
            select(alt)
        }
    }

    // Remember a word the user didn't want converted.
    func learn(_ word: String) {
        ignored.insert(word.lowercased())
    }

    // MARK: Decisions

    func isWord(_ w: String, _ lang: String) -> Bool {
        let r = spell.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                    inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }

    func hasPrefix(_ p: String, _ lang: String) -> Bool {
        if isWord(p, lang) { return true }
        let lower = p.lowercased()
        let c = spell.completions(forPartialWordRange: NSRange(location: 0, length: (lower as NSString).length),
                                  in: lower, language: lang, inSpellDocumentWithTag: 0)
        return !(c ?? []).isEmpty
    }

    func plausible(_ typed: String, _ target: String) -> Bool {
        if ignored.contains(typed.lowercased()) { return false }
        if typed.contains(where: { $0.isNumber }) { return false }
        // Skip acronyms / camelCase: uppercase allowed only as the first letter.
        if typed.dropFirst().contains(where: { $0.isUppercase }) { return false }
        let apostrophes: Set<Character> = ["'", "’", "ʼ"]
        return target.contains(where: { $0.isLetter })
            && target.allSatisfy { $0.isLetter || apostrophes.contains($0) }
    }

    func shouldConvertWord(_ keys: [Key], from cur: Layout, to alt: Layout) -> Bool {
        let a = cur.translate(keys), b = alt.translate(keys)
        guard plausible(a, b), !isWord(a, cur.lang) else { return false }
        if isWord(b, alt.lang) { return true }
        // Names and other words missing from the dictionary: typed text has no vowels at all,
        // while the other layout gives something pronounceable (e.g. мфвнь → vadym).
        return a.count >= 4 && !hasVowel(a, cur.lang) && pronounceable(b, alt.lang)
    }

    static let vowels: [String: Set<Character>] = [
        "uk": Set("аеєиіїоуюя"),
        "en": Set("aeiou"),
    ]

    func hasVowel(_ w: String, _ lang: String) -> Bool {
        guard let v = Engine.vowels[lang] else { return true }
        return w.lowercased().contains(where: v.contains)
    }

    func pronounceable(_ w: String, _ lang: String) -> Bool {
        guard var v = Engine.vowels[lang] else { return false }
        if lang == "en" { v.insert("y") }
        let letters = w.lowercased().filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        var run = 0, maxRun = 0, count = 0
        for ch in letters {
            if v.contains(ch) { count += 1; run = 0 } else { run += 1; maxRun = max(maxRun, run) }
        }
        return Double(count) / Double(letters.count) >= 0.3 && maxRun <= 3
    }

    // 1–2 letter words: the spell checker accepts too many abbreviations, so use fixed lists.
    static let shortWords: [String: Set<String>] = [
        "uk": [
            "і", "в", "у", "з", "а", "я", "о", "й",
            "та", "не", "на", "що", "це", "як", "до", "за", "по", "ти", "ми", "ви", "ці", "ще",
            "же", "чи", "бо", "де", "то", "от", "ні", "її", "їх", "ой", "ну", "аж", "зі", "із", "ок",
            "мо", "во",
        ],
        "en": [
            "a", "i",
            "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it",
            "me", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we",
        ],
    ]

    func shouldConvertShort(_ keys: [Key], from cur: Layout, to alt: Layout) -> Bool {
        let a = cur.translate(keys), b = alt.translate(keys)
        guard plausible(a, b),
              let target = Engine.shortWords[alt.lang], target.contains(b.lowercased()) else { return false }
        return !(Engine.shortWords[cur.lang]?.contains(a.lowercased()) ?? false)
    }

    func shouldConvertPrefix(_ keys: [Key], from cur: Layout, to alt: Layout) -> Bool {
        let a = cur.translate(keys), b = alt.translate(keys)
        guard plausible(a, b) else { return false }
        return !hasPrefix(a, cur.lang) && hasPrefix(b, alt.lang)
    }

    // MARK: Output

    func select(_ l: Layout) {
        expectedSourceID = l.id
        TISSelectInputSource(l.source)
    }

    func replace(deleting n: Int, with text: String, switchTo layout: Layout) {
        for _ in 0..<n { postKey(51) }
        for ch in text {
            if ch == " " { postKey(49) } else { postChar(ch) }
        }
        select(layout)
    }

    func postKey(_ code: CGKeyCode) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { continue }
            e.flags = []
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }

    func postChar(_ ch: Character) {
        let u = Array(String(ch).utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: Tap

    func startTap() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let engine = Unmanaged<Engine>.fromOpaque(refcon!).takeUnretainedValue()
            return engine.handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }
}

// MARK: - App (menu bar)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    var statusItem: NSStatusItem!
    var retryTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "LayoutSwitcher")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.engine.frontApp = app?.bundleIdentifier
            }
            self.engine.resetAll()
        }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let id = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
            if id != nil, id == self.engine.expectedSourceID {
                self.engine.expectedSourceID = nil
            } else {
                self.engine.resetAll()
            }
        }
        dnc.addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                        object: nil, queue: .main) { [weak self] _ in
            self?.engine.reloadLayouts()
        }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        _ = CGRequestListenEventAccess()
        tryStart()
    }

    func tryStart() {
        if engine.startTap() {
            retryTimer?.invalidate()
            retryTimer = nil
            updateIcon()
            return
        }
        updateIcon()
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tryStart() }
        }
    }

    func updateIcon() {
        statusItem.button?.appearsDisabled = !engine.autoEnabled || engine.tap == nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if engine.tap == nil {
            menu.addItem(item("⚠️ Немає дозволів — відкрити налаштування", #selector(openPrivacy)))
            menu.addItem(.separator())
        }

        let auto = item("Автоперемикання", #selector(toggleAuto))
        auto.state = engine.autoEnabled ? .on : .off
        menu.addItem(auto)

        if let app = engine.frontApp {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.localizedName ?? app
            let ex = item("Вимкнути в «\(name)»", #selector(toggleExcluded))
            ex.state = engine.isExcluded() ? .on : .off
            menu.addItem(ex)
        }

        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Подвійний Shift — перекласти останнє слово", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let count = engine.ignored.count
        let clear = item("Очистити список винятків (\(count))", #selector(clearIgnored))
        clear.isEnabled = count > 0
        menu.addItem(clear)

        menu.addItem(.separator())
        let login = item("Запускати при вході", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Вийти", #selector(quit)))
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func toggleAuto() {
        engine.autoEnabled.toggle()
        updateIcon()
    }

    @objc func toggleExcluded() {
        guard let app = engine.frontApp else { return }
        var ex = engine.excluded
        if ex.contains(app) { ex.remove(app) } else { ex.insert(app) }
        engine.excluded = ex
        engine.resetAll()
    }

    @objc func clearIgnored() {
        engine.ignored = []
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не вдалося змінити автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func openPrivacy() {
        for pane in ["Privacy_Accessibility", "Privacy_ListenEvent"] {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Self-test: `LayoutSwitcher --test ghbdsn руддщ ...`

func selfTest(_ words: [String]) {
    let engine = Engine()
    print("Layouts:", engine.layouts.map { "\($0.id) [\($0.lang)]" }.joined(separator: ", "))
    for word in words {
        var result = "?"
        for cur in engine.layouts {
            // Rebuild the key sequence by looking the characters up in this layout.
            var map: [Character: Key] = [:]
            for code in 0..<128 {
                for shift in [false, true] {
                    let k = Key(code: UInt16(code), shift: shift, caps: false)
                    if let c = cur.translate([k]).first, map[c] == nil { map[c] = k }
                }
            }
            let keys = word.compactMap { map[$0] }
            guard keys.count == word.count, let alt = engine.other(than: cur) else { continue }
            let w = keys.count >= 3 ? engine.shouldConvertWord(keys, from: cur, to: alt)
                                    : engine.shouldConvertShort(keys, from: cur, to: alt)
            let p = keys.count >= 4 ? engine.shouldConvertPrefix(Array(keys.prefix(4)), from: cur, to: alt) : false
            result = "\(word) → \(alt.translate(keys))  word:\(w ? "CONVERT" : "keep")  prefix4:\(p ? "CONVERT" : "keep")"
            break
        }
        print(result)
    }
}

let args = CommandLine.arguments
if args.count > 1, args[1] == "--test" {
    selfTest(Array(args.dropFirst(2)))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
