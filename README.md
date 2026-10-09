# LayoutSwitcher

A tiny macOS menu bar app that automatically fixes text typed in the wrong keyboard layout and switches the layout for you (English ↔ Ukrainian).

`ghbdsn` → **привіт** · `руддщ` → **hello** · `oj wt yf` → **що це на** · `мфвнь` → **vadym**

## How it works

- Watches the word you're typing. After 4 letters (or on space for shorter words) it compares the word in both layouts using the macOS built-in spell checker.
- If what you typed isn't a word, but the other layout gives a real word (or a pronounceable name), it erases the text, types the correct version and switches the layout.
- Short words (що, це, на, та, не, в, у, …) are checked against a built-in list.
- **Double Shift** converts the current or last typed word to the other layout. If a word was converted by mistake, double Shift undoes it, and the app remembers the word so it won't touch it again.
- Disabled in terminals and code editors (Terminal, iTerm, Warp, VS Code, Cursor, JetBrains IDEs). You can disable it for any other app from the menu.
- Works fully offline and sends nothing anywhere.

Requires an English layout (ABC / U.S. / British) and any Ukrainian layout. macOS 13+.

## Installation

### Option 1: build from source (recommended)

You need Xcode Command Line Tools. If you don't have them yet:

```bash
xcode-select --install
```

Then:

```bash
git clone https://github.com/VadymShcherbak/LayoutSwitcher.git
cd LayoutSwitcher
./build.sh --install
```

The app is installed to `~/Applications/LayoutSwitcher.app` and launched, and a keyboard icon appears in the menu bar.

### Option 2: prebuilt archive

Download `LayoutSwitcher.zip` from **Releases**, unzip it and move `LayoutSwitcher.app` to `~/Applications` or `/Applications`. The app isn't signed by Apple, so run this once before the first launch:

```bash
xattr -dr com.apple.quarantine ~/Applications/LayoutSwitcher.app
```

## Permissions

macOS will ask for two permissions in **System Settings → Privacy & Security**:

1. **Input Monitoring**
2. **Accessibility**

Enable LayoutSwitcher in both. If the app isn't in the list, click "+" and select `LayoutSwitcher.app` (press Cmd+Shift+G to paste the path). Then **restart the app**.

If the icon menu still says "Немає дозволів" (no permissions), which can happen after an update or rebuild, remove the app from both lists with "−", add it again and restart it.

## Menu

- **Автоперемикання** (auto-switching): turn automatic correction on/off. Double Shift always works.
- **Вимкнути в «…»** (disable in …): don't touch text in the current app.
- **Очистити список винятків** (clear exceptions): forget the words you've undone with double Shift.
- **Запускати при вході** (launch at login): start the app together with your Mac.

## Development

All the code is in a single file: `Sources/main.swift`. You can check how the app decides whether to convert a word without running it in the menu bar:

```bash
./build.sh
build/LayoutSwitcher.app/Contents/MacOS/LayoutSwitcher --test ghbdsn руддщ html
```

`./build.sh --zip` builds `build/LayoutSwitcher.zip` for Releases.
