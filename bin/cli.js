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
const VERSION = require("../package.json").version;

// ── Colors ──────────────────────────────────────────────────────────────

const c = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  orange: "\x1b[38;5;208m",
  peach: "\x1b[38;5;216m",
  green: "\x1b[38;5;114m",
  red: "\x1b[38;5;203m",
  gray: "\x1b[38;5;243m",
  white: "\x1b[38;5;255m",
  cyan: "\x1b[38;5;117m",
  up: "\x1b[1A",
  clearLine: "\x1b[2K",
};

const W = 52;

function center(text, width) {
  const vis = text.replace(/\x1b\[[0-9;]*m/g, "");
  const left = Math.max(0, Math.floor((width - vis.length) / 2));
  const right = Math.max(0, width - vis.length - left);
  return " ".repeat(left) + text + " ".repeat(right);
}

const titleBar = `─── ${c.reset}${c.bold}${c.white}claude-notification${c.reset} ${c.dim}v${VERSION} `;
const titleVis = `─── claude-notification v${VERSION} `;
const titlePad = "─".repeat(Math.max(0, W - titleVis.length));

const LOGO = `
${c.dim}╭${titleBar}${titlePad}╮${c.reset}
${c.dim}│${" ".repeat(W)}│${c.reset}
${c.dim}│${c.reset}${center(`${c.peach}▐▛███▜▌${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${c.reset}${center(`${c.peach}▝▜█████▛▘${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${c.reset}${center(`${c.peach}▘▘ ▝▝${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${" ".repeat(W)}│${c.reset}
${c.dim}│${c.reset}${center(`${c.gray}Native macOS notifications for Claude Code${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}│${c.reset}${center(`${c.dim}by Keshav Narula · x.com/narulakeshav${c.reset}`, W)}${c.dim}│${c.reset}
${c.dim}╰${"─".repeat(W)}╯${c.reset}
`;

function log(msg = "") { console.log(`  ${msg}`); }
function done(msg) { console.log(`  ${c.green}✓${c.reset} ${msg}`); }
function warn(msg) { console.log(`  ${c.red}✗${c.reset} ${msg}`); }
function info(msg) { console.log(`  ${c.gray}${msg}${c.reset}`); }
function hr() { console.log(`  ${c.dim}${"─".repeat(44)}${c.reset}`); }

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

// Spinner for long operations
function spinner(msg) {
  const frames = ["◐", "◓", "◑", "◒"];
  let i = 0;
  process.stdout.write(`  ${c.orange}${frames[0]}${c.reset} ${msg}`);
  const id = setInterval(() => {
    i = (i + 1) % frames.length;
    process.stdout.write(`${c.up}${c.clearLine}\r  ${c.orange}${frames[i]}${c.reset} ${msg}\n`);
  }, 120);
  return {
    stop(doneMsg) {
      clearInterval(id);
      process.stdout.write(`${c.up}${c.clearLine}\r  ${c.green}✓${c.reset} ${doneMsg}\n`);
    },
    fail(failMsg) {
      clearInterval(id);
      process.stdout.write(`${c.up}${c.clearLine}\r  ${c.red}✗${c.reset} ${failMsg}\n`);
    },
  };
}

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
  return new Promise((resolve) => rl.question(`  ${c.orange}?${c.reset} ${question}`, (ans) => { rl.close(); resolve(ans.trim()); }));
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

function findIcon(terminalApp) {
  // Prefer Claude desktop icon
  const claudeIcon = "/Applications/Claude.app/Contents/Resources/electron.icns";
  if (fs.existsSync(claudeIcon)) return { path: claudeIcon, source: "Claude" };

  // Fallback: use selected terminal's icon
  if (terminalApp) {
    try {
      const icnsFiles = execSync(`ls /Applications/${terminalApp}/Contents/Resources/*.icns 2>/dev/null`, { encoding: "utf-8" }).trim().split("\n");
      if (icnsFiles[0]) return { path: icnsFiles[0], source: terminalApp.replace(".app", "") };
    } catch {}
  }

  return null;
}

// Notification preview card
function showPreview(terminal) {
  const project = path.basename(process.cwd());
  log();
  console.log(`  ${c.dim}╭──────────────────────────────────────────╮${c.reset}`);
  console.log(`  ${c.dim}│${c.reset}  ${c.peach}▐▛▜▌${c.reset}  ${c.bold}${c.white}Claude Code · ${project}${c.reset}${" ".repeat(Math.max(0, 24 - project.length))}${c.dim}│${c.reset}`);
  console.log(`  ${c.dim}│${c.reset}  ${c.peach}▝▜█▘${c.reset}  ${c.gray}Waiting for your input${c.reset}              ${c.dim}│${c.reset}`);
  console.log(`  ${c.dim}╰──────────────────────────────────────────╯${c.reset}`);
  info(`  Click → opens ${terminal.name}`);
}

// ── Install ─────────────────────────────────────────────────────────────

async function install() {
  console.log(LOGO);
  hr();
  log();

  // Step 1: Detect or ask terminal
  log(`${c.dim}Step 1 of 4${c.reset}  ${c.white}Terminal${c.reset}`);
  log();

  let terminalKey = detectTerminal();
  if (terminalKey) {
    done(`Detected ${c.bold}${c.white}${TERMINALS[terminalKey].name}${c.reset}`);
    const ok = await ask(`Use ${TERMINALS[terminalKey].name}? ${c.dim}(Y/n)${c.reset} `);
    if (ok.toLowerCase() === "n") terminalKey = null;
  }

  if (!terminalKey) {
    log();
    const keys = Object.keys(TERMINALS);
    keys.forEach((key, i) => {
      const num = `${c.orange}${String(i + 1).padStart(2)}${c.reset}`;
      const name = `${c.white}${TERMINALS[key].name}${c.reset}`;
      console.log(`    ${num}  ${name}`);
    });
    log();
    const choice = await ask(`Pick a terminal ${c.dim}(1-${keys.length})${c.reset}: `);
    const idx = parseInt(choice, 10) - 1;
    if (idx >= 0 && idx < keys.length) {
      terminalKey = keys[idx];
    } else {
      terminalKey = choice.toLowerCase();
    }
    if (!TERMINALS[terminalKey]) {
      warn(`Unknown terminal: ${choice}`);
      process.exit(1);
    }
    done(`Selected ${c.bold}${c.white}${TERMINALS[terminalKey].name}${c.reset}`);
  }

  const terminal = TERMINALS[terminalKey];
  fs.writeFileSync(CONFIG_PATH, JSON.stringify({ terminalBundleId: terminal.bundleId }, null, 2) + "\n");

  // Step 2: Build
  log();
  hr();
  log();
  log(`${c.dim}Step 2 of 4${c.reset}  ${c.white}Build${c.reset}`);
  log();

  fs.mkdirSync(MACOS_DIR, { recursive: true });
  fs.mkdirSync(RESOURCES_DIR, { recursive: true });

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.claude-notify.app</string>
    <key>CFBundleName</key>
    <string>Claude Notification</string>
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

  const icon = findIcon(terminal.app);
  if (icon) {
    fs.copyFileSync(icon.path, path.join(RESOURCES_DIR, "AppIcon.icns"));
    done(`Using ${icon.source} icon`);
  } else {
    info("No icon found — notifications will use default macOS icon");
  }

  const sp = spinner("Compiling native app...\n");
  try {
    execSync(`swiftc -o "${path.join(MACOS_DIR, "notify")}" "${SWIFT_SRC}" -framework Cocoa -framework UserNotifications`, {
      stdio: "pipe",
    });
    sp.stop("Compiled");
  } catch (e) {
    sp.fail("Compilation failed");
    log();
    info("Make sure Xcode Command Line Tools are installed:");
    info("  xcode-select --install");
    process.exit(1);
  }

  // Step 3: Sign & Register
  log();
  hr();
  log();
  log(`${c.dim}Step 3 of 4${c.reset}  ${c.white}Sign & Register${c.reset}`);
  log();

  execSync(`codesign --force --deep --sign - "${APP_PATH}"`, { stdio: "pipe" });
  done("Signed (ad-hoc)");

  execSync(`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_PATH}"`, { stdio: "pipe" });
  done("Registered with macOS");

  const child = spawn("open", [APP_PATH, "--args", "Claude Notify", "Setup complete"]);
  child.unref();
  done("Notification permission requested");

  // Step 4: Configure hook
  log();
  hr();
  log();
  log(`${c.dim}Step 4 of 4${c.reset}  ${c.white}Hook${c.reset}`);
  log();

  const hookCommand = `pkill -f ClaudeNotify.app/Contents/MacOS/notify 2>/dev/null; ${MACOS_DIR}/notify 'Claude Code'`;

  const autoConfig = await ask(`Auto-configure Claude Code hooks? ${c.dim}(Y/n)${c.reset} `);
  if (autoConfig.toLowerCase() !== "n") {
    configureHook(hookCommand);
    done("Updated ~/.claude/settings.json");
  } else {
    log();
    info("Add this to ~/.claude/settings.json:");
    log();
    console.log(`  ${c.dim}{${c.reset}`);
    console.log(`  ${c.dim}  "hooks": {${c.reset}`);
    console.log(`  ${c.dim}    "Notification": [{${c.reset}`);
    console.log(`  ${c.dim}      "matcher": "*",${c.reset}`);
    console.log(`  ${c.dim}      "hooks": [{ "type": "command", "command": "${hookCommand}" }]${c.reset}`);
    console.log(`  ${c.dim}    }]${c.reset}`);
    console.log(`  ${c.dim}  }${c.reset}`);
    console.log(`  ${c.dim}}${c.reset}`);
  }

  // Finale
  log();
  hr();
  log();

  showPreview(terminal);

  log();
  hr();
  log();
  console.log(`  ${c.orange}◆${c.reset} ${c.bold}${c.white}You're all set!${c.reset}`);
  log();
  info("1. Enable notifications: System Settings → Notifications → Claude Notification");
  info(`2. Test it: ${c.white}npx claude-notification test${c.reset}`);
  log();
  info(`${c.dim}Notifications will show the Claude icon, your project name,${c.reset}`);
  info(`${c.dim}and what Claude needs — click to jump back to ${terminal.name}.${c.reset}`);
  log();
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
}

// ── Uninstall ───────────────────────────────────────────────────────────

function uninstall() {
  console.log(LOGO);
  hr();
  log();

  if (fs.existsSync(APP_PATH)) {
    fs.rmSync(APP_PATH, { recursive: true });
    done("Removed ~/Applications/ClaudeNotify.app");
  }
  if (fs.existsSync(CONFIG_PATH)) {
    fs.unlinkSync(CONFIG_PATH);
    done("Removed ~/.claude-notify.json");
  }

  if (fs.existsSync(SETTINGS_PATH)) {
    const settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf-8"));
    if (settings.hooks?.Notification) {
      settings.hooks.Notification = settings.hooks.Notification.filter(
        (n) => !n.hooks?.some((h) => h.command?.includes("ClaudeNotify"))
      );
      if (settings.hooks.Notification.length === 0) delete settings.hooks.Notification;
      if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
      fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
      done("Removed hook from ~/.claude/settings.json");
    }
  }

  log();
  console.log(`  ${c.orange}◆${c.reset} ${c.bold}${c.white}Uninstalled.${c.reset} ${c.dim}Thanks for trying claude-notification!${c.reset}`);
  log();
}

// ── Test ────────────────────────────────────────────────────────────────

function test() {
  if (!fs.existsSync(path.join(MACOS_DIR, "notify"))) {
    warn(`Not installed. Run: ${c.white}npx claude-notification install${c.reset}`);
    process.exit(1);
  }

  const testPayload = JSON.stringify({
    message: "This is a test notification",
    notification_type: "idle_prompt",
    cwd: process.cwd(),
  });

  try { execSync("pkill -f ClaudeNotify.app/Contents/MacOS/notify 2>/dev/null", { stdio: "pipe" }); } catch {}

  const child = spawn(path.join(MACOS_DIR, "notify"), ["Claude Code"], {
    stdio: ["pipe", "inherit", "inherit"],
  });
  child.stdin.write(testPayload);
  child.stdin.end();
  child.unref();

  log();
  done("Sent test notification");
  info("Check your notification center");
  log();
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
    console.log(LOGO);
    hr();
    log();
    log(`${c.white}Usage:${c.reset}`);
    log();
    log(`  ${c.orange}install${c.reset}     Set up notifications`);
    log(`  ${c.orange}test${c.reset}        Send a test notification`);
    log(`  ${c.orange}uninstall${c.reset}   Remove everything`);
    log();
    info(`npx claude-notification install`);
    log();
}
