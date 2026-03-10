# claude-notification

Native macOS notifications for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — with the Claude icon, click-to-focus terminal, and contextual messages.

Built because `terminal-notifier`'s `-sender` and `-appIcon` flags are [broken on macOS Ventura+](https://github.com/julienXX/terminal-notifier/pull/317), and `osascript` notifications can't use custom icons.

## What you get

- Claude icon on every notification
- Click notification to focus your terminal
- Contextual body — shows permission requests, idle prompts, etc.
- Project name in the title (e.g. "Claude Code · my-project")
- Sound alerts

## Install

```bash
npx claude-notification install
```

This will:

1. Detect your terminal (Warp, iTerm2, Terminal, VS Code, Cursor, Kitty, Alacritty, Ghostty)
2. Compile a lightweight native macOS app (~100KB)
3. Sign it (ad-hoc, no Apple Developer account needed)
4. Register it with macOS for notification permissions
5. Auto-configure your Claude Code hook in `~/.claude/settings.json`

### Requirements

- macOS 13+ (Ventura, Sonoma, Sequoia)
- Xcode Command Line Tools (`xcode-select --install`)
- [Claude desktop app](https://claude.ai/download) installed (for the icon)

## Test

```bash
npx claude-notification test
```

## Uninstall

```bash
npx claude-notification uninstall
```

Removes the app, config, and Claude Code hook.

## How it works

The installer creates a minimal `.app` bundle at `~/Applications/Claude Notification.app`. This is the only way to get a custom notification icon on modern macOS — notifications inherit the icon from the sending app bundle.

Claude Code's [notification hook](https://docs.anthropic.com/en/docs/claude-code/hooks) pipes JSON context (message, type, working directory) to the app via stdin. The app parses this to show contextual notifications.

## Supported terminals

| Terminal | Auto-detected |
|----------|:---:|
| Warp | Yes |
| iTerm2 | Yes |
| Terminal.app | Yes |
| VS Code | Yes |
| Cursor | Yes |
| Kitty | - |
| Alacritty | - |
| Ghostty | Yes |

Terminals not auto-detected can be selected during install.

## License

MIT
