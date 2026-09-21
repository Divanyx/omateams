#!/usr/bin/env node
// Runs the QML theme mapper under node: parse real Omarchy themes, build the
// CSS and check the invariants the Teams page depends on.
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "host", "qml", "Theme.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const Theme = {}
new Function("exports", source + "\n" + [
  "parseColors", "buildCss", "palette", "tokens", "pageScript", "mix", "alpha", "contrast", "luminance", "radii"
].map(n => `exports.${n} = ${n};`).join("\n"))(Theme)

const themesDir = "/usr/share/omarchy/themes"
const names = fs.existsSync(themesDir) ? fs.readdirSync(themesDir).filter(n => fs.existsSync(path.join(themesDir, n, "colors.toml"))) : []
assert(names.length > 0, "no Omarchy themes found to test against")

const REQUIRED = [
  "colorNeutralBackground1", "colorNeutralBackground2", "colorNeutralBackground3",
  "colorNeutralForeground1", "colorNeutralForeground2", "colorNeutralForeground3",
  "colorBrandBackground", "colorBrandForeground1", "colorNeutralForegroundOnBrand",
  "colorNeutralStroke1", "colorSubtleBackgroundHover", "colorStatusDangerForeground1",
  "colorStatusSuccessBackground3", "colorStatusWarningBorder1", "colorStrokeFocus2"
]

let checked = 0
for (const name of names) {
  const colors = Theme.parseColors(fs.readFileSync(path.join(themesDir, name, "colors.toml"), "utf8"))
  const p = Theme.palette(colors)
  const t = Theme.tokens(p)
  for (const key of REQUIRED) assert(t[key], `${name}: token ${key} missing`)
  const count = Object.keys(t).length
  assert(count >= 200, `${name}: only ${count} tokens`)
  // Text must stay readable on the main surface and on the accent.
  assert(Theme.contrast(p.bg, p.fg) >= 4.5, `${name}: fg/bg contrast ${Theme.contrast(p.bg, p.fg).toFixed(2)}`)
  assert(Theme.contrast(p.accent, p.onBrand) >= 3, `${name}: onBrand contrast ${Theme.contrast(p.accent, p.onBrand).toFixed(2)}`)
  // Deep surfaces step away from the main one in both modes. A pure-black
  // theme has nowhere deeper to go, so its own dark_background may sit a hair
  // above it; anything more than that is a mapping bug.
  const l = [p.bg, p.bg2, p.bg3, p.bg4, p.bg5].map(Theme.luminance)
  for (let i = 1; i < l.length; i++) assert(l[i] <= l[i - 1] + 0.03, `${name}: surface ${i} is not deeper`)
  const css = Theme.buildCss(colors, { fontFamily: "monospace", rounding: 8 })
  assert(css.includes("--colorNeutralBackground1: " + p.bg + " !important"), `${name}: css lacks bg token`)
  assert(css.includes("--borderRadiusMedium: 4px"), `${name}: radii missing`)
  assert(css.includes("--fontFamilyBase: monospace"), `${name}: font missing`)
  assert(css.includes(`color-scheme: ${p.mode}`), `${name}: color-scheme`)
  const script = Theme.pageScript(css)
  new Function(script)  // must at least parse
  checked++
}

// Sharp themes get sharp corners, missing rounding leaves Fluent's defaults.
assert.strictEqual(Theme.radii(0).borderRadiusXLarge, "0px")
assert.deepStrictEqual(Theme.radii(-1), {})
assert.deepStrictEqual(Theme.radii(undefined), {})
assert(!Theme.buildCss({}, {}).includes("--borderRadius"), "radii emitted without rounding")
assert(!Theme.buildCss({}, {}).includes("--fontFamilyBase"), "font emitted without family")

// A theme without optional keys still yields a full palette.
const minimal = Theme.palette({ background: "#000000", foreground: "#ffffff", accent: "#ff0000" })
assert.strictEqual(minimal.mode, "dark")
assert(Object.keys(Theme.tokens(minimal)).length >= 200)

console.log(`ok - ${checked} themes, ${Object.keys(Theme.tokens(Theme.palette({}))).length} tokens each`)
