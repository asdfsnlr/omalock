#!/usr/bin/env bash
#
# My Lock Screen installer — customizable lock screen for Omarchy.
#
# Run it from a clone of the repo:  ./install.sh
#
# What it does:
#   1. Registers the plugin (omarchy plugin add — never a file copy, or
#      `omarchy plugin update` could never fast-forward it later).
#   2. Enables the plugin service.
#   3. Registers the "Omalock" entry in the Omarchy menu
#      (~/.config/omarchy/extensions/omarchy-menu.jsonc) under Style category ("style.lock").
#
# Overrides:
#   OMALOCK_REPO=user/repo         register the plugin from a different repo (default: asdfsnlr/omalock)
set -euo pipefail

REPO="${OMALOCK_REPO:-asdfsnlr/omalock}"
PLUGIN_ID="asdfsnlr.omalock"
MENU_FILE="${HOME}/.config/omarchy/extensions/omarchy-menu.jsonc"

say() { printf '%s\n' "$*"; }

if ! command -v omarchy >/dev/null 2>&1; then
  say "This needs Omarchy 4 (the omarchy CLI is not on PATH)."
  exit 1
fi

if [[ "$REPO" =~ ^https?:// || "$REPO" =~ ^git@ ]]; then
  REPO_URL="$REPO"
else
  REPO_URL="https://github.com/${REPO}"
fi

# Already installed? Then this is an update, not an install.
if omarchy plugin list 2>/dev/null | grep -q "^${PLUGIN_ID}[[:space:]]"; then
  say "==> ${PLUGIN_ID} is already installed"
  if [ -d "${HOME}/.config/omarchy/plugins/${PLUGIN_ID}/.git" ]; then
    say "==> Updating ${PLUGIN_ID}"
    omarchy plugin update "$PLUGIN_ID"
  else
    say "==> ${PLUGIN_ID} is a local non-git directory; skipping git pull"
  fi
else
  say "==> Registering ${PLUGIN_ID} from ${REPO_URL}"
  # --yes only when there is no terminal to prompt on
  if [ -t 0 ] && [ -t 1 ]; then
    omarchy plugin add "$REPO_URL"
  else
    omarchy plugin add "$REPO_URL" --yes
  fi
fi

say "==> Enabling ${PLUGIN_ID}"
omarchy plugin enable "$PLUGIN_ID" || true

CLI_SOURCE="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}/bin/omalock"
if [ -f "$CLI_SOURCE" ]; then
  say "==> Linking the omalock CLI into ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  ln -sf "$CLI_SOURCE" "${HOME}/.local/bin/omalock"
  case ":$PATH:" in
    *":${HOME}/.local/bin:"*) ;;
    *) say "    Note: ~/.local/bin is not on your PATH yet — add it to use 'omalock' directly, or run ${CLI_SOURCE}" ;;
  esac
fi

say "==> Registering menu entry in ${MENU_FILE}"
NODE_BIN="$(command -v node 2>/dev/null || echo "/usr/bin/node")"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  say "Warning: node is not available to update ${MENU_FILE}; please add the menu entry manually."
else
  STATUS=$("$NODE_BIN" - "$MENU_FILE" << 'EOF'
const fs = require('fs');
const path = require('path');

const menuFile = process.argv[2];
const key = 'style.lock';
const legacyKey = 'slanger.lock.settings';
const newEntryObj = {
  icon: '',
  label: 'Omalock',
  description: 'Customize clock, weather, avatar, and media player widgets',
  action: 'omarchy-shell asdfsnlr.omalock openSettings'
};
const newEntryStr = `  "${key}": ${JSON.stringify(newEntryObj)}`;

function stripJsonc(content) {
  return content
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/,(\s*[}\]])/g, '$1');
}

if (!fs.existsSync(menuFile)) {
  fs.mkdirSync(path.dirname(menuFile), { recursive: true });
  const initialContent = `{\n  // User menu extensions\n${newEntryStr}\n}\n`;
  fs.writeFileSync(menuFile, initialContent, 'utf8');
  console.log('created');
  process.exit(0);
}

const original = fs.readFileSync(menuFile, 'utf8');
let parsed = {};
try {
  parsed = JSON.parse(stripJsonc(original));
} catch (e) {
  console.error('Warning: could not parse JSONC in ' + menuFile + ': ' + e.message);
}

// 1. Check if legacyKey exists and migrate in place
if (parsed && typeof parsed === 'object' && Object.prototype.hasOwnProperty.call(parsed, legacyKey)) {
  const regex = new RegExp(`("${legacyKey.replace(/\\./g, '\\.')}"\\s*:\\s*\\{[^\\}]*\\})`, 'm');
  if (regex.test(original)) {
    const updated = original.replace(regex, `"${key}": ${JSON.stringify(newEntryObj)}`);
    fs.writeFileSync(menuFile, updated, 'utf8');
    console.log('migrated');
    process.exit(0);
  }
}

// 2. Check if key already exists
if (parsed && typeof parsed === 'object' && Object.prototype.hasOwnProperty.call(parsed, key)) {
  const current = parsed[key];
  if (
    current &&
    current.icon === newEntryObj.icon &&
    current.label === newEntryObj.label &&
    current.description === newEntryObj.description &&
    current.action === newEntryObj.action
  ) {
    console.log('unchanged');
    process.exit(0);
  }

  const regex = new RegExp(`("${key.replace(/\\./g, '\\.')}"\\s*:\\s*\\{[^\\}]*\\})`, 'm');
  if (regex.test(original)) {
    const updated = original.replace(regex, `"${key}": ${JSON.stringify(newEntryObj)}`);
    fs.writeFileSync(menuFile, updated, 'utf8');
    console.log('updated');
    process.exit(0);
  }
}

// 3. Insert before last closing brace
const lastBraceIdx = original.lastIndexOf('}');
if (lastBraceIdx === -1) {
  const updated = `{\n${newEntryStr}\n}\n`;
  fs.writeFileSync(menuFile, updated, 'utf8');
  console.log('created');
  process.exit(0);
}

const beforeBrace = original.slice(0, lastBraceIdx);
const afterBrace = original.slice(lastBraceIdx);

const strippedBefore = stripJsonc(beforeBrace).trim();
let needsComma = false;
if (strippedBefore && !strippedBefore.endsWith('{') && !strippedBefore.endsWith(',')) {
  needsComma = true;
}

let insertion = '';
if (needsComma) {
  const lines = beforeBrace.split('\n');
  let lastLineIdx = lines.length - 1;
  while (lastLineIdx >= 0 && (lines[lastLineIdx].trim() === '' || lines[lastLineIdx].trim().startsWith('//'))) {
    lastLineIdx--;
  }
  if (lastLineIdx >= 0 && !lines[lastLineIdx].trim().endsWith(',')) {
    lines[lastLineIdx] = lines[lastLineIdx] + ',';
  }
  const rebuiltBefore = lines.join('\n');
  const trailingNewline = rebuiltBefore.endsWith('\n') ? '' : '\n';
  insertion = `${rebuiltBefore}${trailingNewline}${newEntryStr}\n${afterBrace}`;
} else {
  const trailingNewline = beforeBrace.endsWith('\n') ? '' : '\n';
  insertion = `${beforeBrace}${trailingNewline}${newEntryStr}\n${afterBrace}`;
}

fs.writeFileSync(menuFile, insertion, 'utf8');
console.log('added');
EOF
  )

  case "$STATUS" in
    created)
      say "==> Created ${MENU_FILE} with Omalock menu entry"
      ;;
    added)
      say "==> Added Omalock menu entry to ${MENU_FILE}"
      ;;
    migrated)
      say "==> Migrated lock screen settings entry to style.lock (Omalock) in ${MENU_FILE}"
      ;;
    updated)
      say "==> Updated Omalock menu entry in ${MENU_FILE}"
      ;;
    unchanged)
      say "==> Menu entry in ${MENU_FILE} is up to date"
      ;;
    *)
      say "==> Menu update: ${STATUS}"
      ;;
  esac
fi

say ""
say "Done. Open settings from the Omarchy menu (Super key -> Style -> Omalock), or run:"
say "  omarchy-shell ${PLUGIN_ID} openSettings"
say ""
say "To preview the lock screen, run:"
say "  omarchy-shell lock preview"
