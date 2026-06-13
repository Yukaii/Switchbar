# Switchbar

A native macOS menu bar utility for quickly switching your default browser.

Inspired by [Default Browser](https://sindresorhus.com/default-browser) by Sindre Sorhus.

## Features

- Menu bar browser switching with keyboard shortcut (Option+Space)
- Current default browser detection
- Automatic discovery of unsupported default browsers
- Browser visibility settings
- Menu bar icon modes
- Local preference persistence

## Install

### Homebrew

```sh
brew tap Yukaii/tap
brew install switchbar
```

To auto-start on login:

```sh
brew services start switchbar
```

To stop auto-starting:

```sh
brew services stop switchbar
```

To install the latest unreleased version from `main`:

```sh
brew install switchbar --HEAD
```

### Build from source

```sh
swift build -c release
.build/release/Switchbar &
```

## Usage

Switchbar appears in the macOS menu bar. Click it to see your browsers, or press **Option+Space** to open the menu from anywhere.

Select a browser by clicking or pressing its number key (1-9).

## Reference

This project is inspired by [Default Browser](https://sindresorhus.com/default-browser) by Sindre Sorhus. See the [scripting section](https://sindresorhus.com/default-browser#scripting) for ideas on automating browser switching with Shortcuts, Focus filters, and more.

## License

MIT
