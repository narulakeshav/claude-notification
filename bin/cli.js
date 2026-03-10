#!/usr/bin/env node

const { execSync, spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const HOME = process.env.HOME;
const APP_DIR = path.join(HOME, "Applications");
const APP_PATH = path.join(APP_DIR, "ClaudeNotify.app");
const MACOS_DIR = path.join(APP_PATH, "Contents", "MacOS");
const RESOURCES_DIR = path.join(APP_PATH, "Contents", "Resources");
const CONFIG_PATH = path.join(HOME, ".claude-notify.json");
const SWIFT_SRC = path.join(__dirname, "..", "src", "notify.swift");
const SETTINGS_PATH = path.join(HOME, ".claude", "settings.json");

// ── Terminal presets ────────────────────────────────────────────────────

const TERMINALS = {
  warp: { name: "Warp", bundleId: "dev.warp.Warp-Stable", app: "Warp.app" },
  iterm: { name: "iTerm2", bundleId: "com.googlecode.iterm2", app: "iTerm.app" },
  terminal: { name: "Terminal", bundleId: "com.apple.Terminal", app: "Terminal.app" },
  vscode: { name: "VS Code", bundleId: "com.microsoft.VSCode", app: "Visual Studio Code.app" },
  cursor: { name: "Cursor", bundleId: "com.todesktop.230313mzl4w4u92", app: "Cursor.app" },
  kitty: { name: "Kitty", bundleId: "net.kovidgoyal.kitty", app: "kitty.app" },
  alacritty: { name: "Alacritty", bundleId: "org.alacritty", app: "Alacritty.app" },
  ghostty: { name: "Ghostty", bundleId: "com.mitchellh.ghostty", app: "Ghostty.app" },
};

// ── Helpers ─────────────────────────────────────────────────────────────

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => rl.question(question, (ans) => { rl.close(); resolve(ans.trim()); }));
}

function detectTerminal() {
  const termProgram = process.env.TERM_PROGRAM || "";
  if (termProgram.includes("Warp")) return "warp";
  if (termProgram.includes("iTerm")) return "iterm";
  if (termProgram === "Apple_Terminal") return "terminal";
  if (termProgram === "vscode") return "vscode";
  if (termProgram === "cursor") return "cursor";
  if (termProgram === "ghostty") return "ghostty";
  return null;
}

function findIcon() {
  // Try Claude desktop app first
  const claudeIcon = "/Applications/Claude.app/Contents/Resources/electron.icns";
  if (fs.existsSync(claudeIcon)) return claudeIcon;

  // Fallback: generic app icon
  return null;
}

// ── Install ─────────────────────────────────────────────────────────────

async function install() {
  console.log("\n  Claude Notify — Setup\n");

  // 1. Detect or ask terminal
  let terminalKey = detectTerminal();
  if (terminalKey) {
    console.log(`  Detected terminal: ${TERMINALS[terminalKey].name}`);
    const ok = await ask("  Use this? (Y/n) ");
    if (ok.toLowerCase() === "n") terminalKey = null;
  }

  if (!terminalKey) {
    console.log("\n  Available terminals:");
    Object.entries(TERMINALS).forEach(([key, val]) => {
      console.log(`    ${key.padEnd(12)} ${val.name}`);
    });
    const choice = await ask("\n  Which terminal? ");
    terminalKey = choice.toLowerCase();
    if (!TERMINALS[terminalKey]) {
      console.error(`  Unknown terminal: ${choice}`);
      process.exit(1);
    }
  }

  const terminal = TERMINALS[terminalKey];
  console.log(`\n  Setting up for ${terminal.name}...`);

  // 2. Write config
  fs.writeFileSync(CONFIG_PATH, JSON.stringify({ terminalBundleId: terminal.bundleId }, null, 2) + "\n");
  console.log("  Wrote ~/.claude-notify.json");

  // 3. Create .app bundle
  fs.mkdirSync(MACOS_DIR, { recursive: true });
  fs.mkdirSync(RESOURCES_DIR, { recursive: true });

  // Info.plist
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.claude-notify.app</string>
    <key>CFBundleName</key>
    <string>ClaudeNotify</string>
    <key>CFBundleExecutable</key>
    <string>notify</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSUserNotificationAlertStyle</key>
    <string>banner</string>
</dict>
</plist>`;
  fs.writeFileSync(path.join(APP_PATH, "Contents", "Info.plist"), plist);

  // Copy icon
  const iconSrc = findIcon();
  if (iconSrc) {
    fs.copyFileSync(iconSrc, path.join(RESOURCES_DIR, "AppIcon.icns"));
    console.log("  Using Claude icon");
  } else {
    console.log("  No Claude desktop app found — using default icon");
  }

  // 4. Compile Swift
  console.log("  Compiling...");
  try {
    execSync(`swiftc -o "${path.join(MACOS_DIR, "notify")}" "${SWIFT_SRC}" -framework Cocoa -framework UserNotifications`, {
      stdio: "pipe",
    });
  } catch (e) {
    console.error("  Compilation failed. Make sure Xcode Command Line Tools are installed:");
    console.error("  xcode-select --install");
    process.exit(1);
  }

  // 5. Codesign
  execSync(`codesign --force --deep --sign - "${APP_PATH}"`, { stdio: "pipe" });
  console.log("  Signed (ad-hoc)");

  // 6. Register with LaunchServices
  execSync(`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_PATH}"`, { stdio: "pipe" });
  console.log("  Registered with macOS");

  // 7. Trigger first launch to prompt for notification permissions
  console.log("\n  Requesting notification permission...");
  const child = spawn("open", [APP_PATH, "--args", "Claude Notify", "Setup complete"]);
  child.unref();

  // 8. Show hook config
  const hookCommand = `pkill -f ClaudeNotify.app/Contents/MacOS/notify 2>/dev/null; ${MACOS_DIR}/notify 'Claude Code'`;

  console.log("\n  Done! Now:\n");
  console.log("  1. Allow notifications when macOS prompts (or enable in System Settings → Notifications → ClaudeNotify)");
  console.log(`\n  2. Add this to ~/.claude/settings.json:\n`);
  console.log(`  {`);
  console.log(`    "hooks": {`);
  console.log(`      "Notification": [{`);
  console.log(`        "matcher": "*",`);
  console.log(`        "hooks": [{`);
  console.log(`          "type": "command",`);
  console.log(`          "command": "${hookCommand}"`);
  console.log(`        }]`);
  console.log(`      }]`);
  console.log(`    }`);
  console.log(`  }`);

  const autoConfig = await ask("\n  Auto-configure Claude Code hooks? (Y/n) ");
  if (autoConfig.toLowerCase() !== "n") {
    configureHook(hookCommand);
  }

  console.log("\n  All set!\n");
}

// ── Auto-configure hook ─────────────────────────────────────────────────

function configureHook(hookCommand) {
  let settings = {};
  if (fs.existsSync(SETTINGS_PATH)) {
    settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf-8"));
  } else {
    fs.mkdirSync(path.dirname(SETTINGS_PATH), { recursive: true });
  }

  if (!settings.hooks) settings.hooks = {};
  settings.hooks.Notification = [
    {
      matcher: "*",
      hooks: [{ type: "command", command: hookCommand }],
    },
  ];

  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
  console.log("  Updated ~/.claude/settings.json");
}

// ── Uninstall ───────────────────────────────────────────────────────────

function uninstall() {
  console.log("\n  Removing Claude Notify...\n");

  if (fs.existsSync(APP_PATH)) {
    fs.rmSync(APP_PATH, { recursive: true });
    console.log("  Removed ~/Applications/ClaudeNotify.app");
  }
  if (fs.existsSync(CONFIG_PATH)) {
    fs.unlinkSync(CONFIG_PATH);
    console.log("  Removed ~/.claude-notify.json");
  }

  // Remove hook from settings
  if (fs.existsSync(SETTINGS_PATH)) {
    const settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf-8"));
    if (settings.hooks?.Notification) {
      settings.hooks.Notification = settings.hooks.Notification.filter(
        (n) => !n.hooks?.some((h) => h.command?.includes("ClaudeNotify"))
      );
      if (settings.hooks.Notification.length === 0) delete settings.hooks.Notification;
      if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
      fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
      console.log("  Removed hook from ~/.claude/settings.json");
    }
  }

  console.log("\n  Done!\n");
}

// ── Test ────────────────────────────────────────────────────────────────

function test() {
  if (!fs.existsSync(path.join(MACOS_DIR, "notify"))) {
    console.error("  Not installed. Run: npx claude-notification install");
    process.exit(1);
  }

  const testPayload = JSON.stringify({
    message: "This is a test notification",
    notification_type: "idle_prompt",
    cwd: process.cwd(),
  });

  const child = spawn(path.join(MACOS_DIR, "notify"), ["Claude Code"], {
    stdio: ["pipe", "inherit", "inherit"],
  });
  child.stdin.write(testPayload);
  child.stdin.end();
  child.unref();
  console.log("  Sent test notification");
}

// ── CLI ─────────────────────────────────────────────────────────────────

const command = process.argv[2];

switch (command) {
  case "install":
    install();
    break;
  case "uninstall":
    uninstall();
    break;
  case "test":
    test();
    break;
  default:
    console.log("\n  claude-notification — Native macOS notifications for Claude Code\n");
    console.log("  Usage:");
    console.log("    npx claude-notification install     Set up notifications");
    console.log("    npx claude-notification test        Send a test notification");
    console.log("    npx claude-notification uninstall   Remove everything\n");
}
