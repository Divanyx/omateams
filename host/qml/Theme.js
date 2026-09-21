.pragma library

// Omarchy theme -> Fluent UI v9 design tokens.
//
// Teams (the current web client) is built on Fluent UI v9, which paints every
// surface from CSS custom properties such as --colorNeutralBackground1 and
// --colorBrandBackground. Re-defining those properties from the Omarchy theme
// re-skins the whole application without touching a single Teams selector.
// The mapping below derives every alias token from the handful of colors an
// Omarchy theme ships in colors.toml (background, foreground, accent, the
// dark/light surface variants and the ANSI-ish status colors).
//
// Everything here is plain ECMAScript so it runs both inside the QML engine
// and under node for the unit tests in tests/theme.test.js.

function parseColors(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']([^"']*)["']/)
    if (m) out[m[1]] = m[2].trim()
  }
  return out
}

function isColor(v) {
  return typeof v === "string" && /^#[0-9a-fA-F]{6}$/.test(v)
}

function hexToRgb(hex) {
  var h = String(hex).replace("#", "")
  if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
  if (h.length !== 6) return null
  var n = parseInt(h, 16)
  if (isNaN(n)) return null
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 }
}

function toHex2(n) {
  var s = Math.max(0, Math.min(255, Math.round(n))).toString(16)
  return s.length < 2 ? "0" + s : s
}

function rgbToHex(c) {
  return "#" + toHex2(c.r) + toHex2(c.g) + toHex2(c.b)
}

// Linear blend from a to b: t = 0 gives a, t = 1 gives b.
function mix(a, b, t) {
  var ca = hexToRgb(a), cb = hexToRgb(b)
  if (!ca || !cb) return a
  t = Math.max(0, Math.min(1, t))
  return rgbToHex({
    r: ca.r + (cb.r - ca.r) * t,
    g: ca.g + (cb.g - ca.g) * t,
    b: ca.b + (cb.b - ca.b) * t
  })
}

function alpha(hex, a) {
  var c = hexToRgb(hex)
  if (!c) return hex
  return "rgba(" + c.r + ", " + c.g + ", " + c.b + ", " + Math.max(0, Math.min(1, a)) + ")"
}

function channel(v) {
  v /= 255
  return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

// WCAG relative luminance, 0 (black) .. 1 (white).
function luminance(hex) {
  var c = hexToRgb(hex)
  if (!c) return 0
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
}

function contrast(a, b) {
  var la = luminance(a), lb = luminance(b)
  var hi = Math.max(la, lb), lo = Math.min(la, lb)
  return (hi + 0.05) / (lo + 0.05)
}

// The candidate that reads best on `bg`. Theme colors are tried first so text
// on the accent stays inside the palette; pure black/white are the last resort
// for accents that neither theme color can sit on.
function readableOn(bg, candidates) {
  var best = candidates[0], bestRatio = 0
  for (var i = 0; i < candidates.length; i++) {
    var r = contrast(bg, candidates[i])
    if (r > bestRatio) { best = candidates[i]; bestRatio = r }
    if (i === 1 && bestRatio >= 4.5) break
  }
  return best
}

function pick(v, fallback) {
  return isColor(v) ? v : fallback
}

// Derive the working palette from colors.toml. Fluent's Background2..5 step
// away from Background1 into the "deep" direction in both modes (darker on a
// dark theme, still darker on a light one), which is exactly what Omarchy's
// dark_background / darker_background describe.
function palette(colors) {
  colors = colors || {}
  var mode = String(colors.mode || "dark").toLowerCase() === "light" ? "light" : "dark"
  var dark = mode === "dark"
  var black = "#000000", white = "#ffffff"
  var bg = pick(colors.background, dark ? "#101315" : "#f4f4f4")
  var fg = pick(colors.foreground, dark ? "#cacccc" : "#242424")
  var accent = pick(colors.accent, pick(colors.blue, fg))

  function deep(c, t) { return mix(c, black, t) }
  function raise(c, t) { return mix(c, fg, t) }

  var bg2 = pick(colors.dark_background, deep(bg, dark ? 0.22 : 0.04))
  var bg3 = pick(colors.darker_background, deep(bg2, dark ? 0.22 : 0.04))
  var bg4 = deep(bg3, dark ? 0.2 : 0.04)
  var bg5 = deep(bg4, dark ? 0.2 : 0.04)
  var bg6 = dark ? raise(bg, 0.07) : deep(bg, 0.08)
  var card = dark ? raise(bg, 0.05) : deep(bg, 0.02)

  var fg2 = isColor(colors.light_foreground) && colors.light_foreground.toLowerCase() !== fg.toLowerCase()
    ? colors.light_foreground : mix(fg, bg, 0.18)
  var fg3 = pick(colors.dark_foreground, mix(fg, bg, 0.42))
  var fg4 = mix(fg, bg, 0.55)

  var brandHover = dark ? mix(accent, white, 0.12) : mix(accent, black, 0.12)
  var brandPressed = dark ? mix(accent, white, 0.22) : mix(accent, black, 0.22)
  var brandSoft = dark ? mix(accent, white, 0.2) : mix(accent, black, 0.2)

  return {
    mode: mode, dark: dark,
    bg: bg, bg2: bg2, bg3: bg3, bg4: bg4, bg5: bg5, bg6: bg6, card: card,
    fg: fg, fg2: fg2, fg3: fg3, fg4: fg4,
    disabled: mix(fg, bg, 0.66),
    selection: pick(colors.selection, mix(accent, bg, 0.8)),
    accent: accent, brandHover: brandHover, brandPressed: brandPressed, brandSoft: brandSoft,
    onBrand: readableOn(accent, [bg, fg, black, white]),
    red: pick(colors.red, "#d13438"),
    green: pick(colors.green, "#107c10"),
    yellow: pick(colors.yellow, pick(colors.orange, "#f7630c")),
    orange: pick(colors.orange, pick(colors.yellow, "#f7630c")),
    blue: pick(colors.blue, accent),
    raise: raise, deep: deep
  }
}

function tokens(p) {
  var t = {}
  var fg = p.fg, bg = p.bg, accent = p.accent
  var raise = p.raise

  // --- neutral foreground ------------------------------------------------
  t.colorNeutralForeground1 = fg
  t.colorNeutralForeground1Hover = fg
  t.colorNeutralForeground1Pressed = fg
  t.colorNeutralForeground1Selected = fg
  t.colorNeutralForeground2 = p.fg2
  t.colorNeutralForeground2Hover = fg
  t.colorNeutralForeground2Pressed = fg
  t.colorNeutralForeground2Selected = fg
  t.colorNeutralForeground2BrandHover = accent
  t.colorNeutralForeground2BrandPressed = p.brandPressed
  t.colorNeutralForeground2BrandSelected = accent
  t.colorNeutralForeground3 = p.fg3
  t.colorNeutralForeground3Hover = p.fg2
  t.colorNeutralForeground3Pressed = p.fg2
  t.colorNeutralForeground3Selected = p.fg2
  t.colorNeutralForeground3BrandHover = accent
  t.colorNeutralForeground3BrandPressed = p.brandPressed
  t.colorNeutralForeground3BrandSelected = accent
  t.colorNeutralForeground4 = p.fg4
  t.colorNeutralForeground5 = p.fg4
  t.colorNeutralForeground5Hover = p.fg3
  t.colorNeutralForeground5Pressed = p.fg3
  t.colorNeutralForeground5Selected = p.fg3
  t.colorNeutralForegroundDisabled = p.disabled
  t.colorNeutralForegroundInvertedDisabled = alpha(bg, 0.4)
  t.colorNeutralForeground1Static = fg
  t.colorNeutralForegroundInverted = bg
  t.colorNeutralForegroundInvertedHover = bg
  t.colorNeutralForegroundInvertedPressed = bg
  t.colorNeutralForegroundInvertedSelected = bg
  t.colorNeutralForegroundInverted2 = bg
  t.colorNeutralForegroundOnBrand = p.onBrand
  t.colorNeutralForegroundStaticInverted = "#ffffff"
  t.colorNeutralForegroundInvertedLink = bg
  t.colorNeutralForegroundInvertedLinkHover = bg
  t.colorNeutralForegroundInvertedLinkPressed = bg
  t.colorNeutralForegroundInvertedLinkSelected = bg

  // --- brand foreground ----------------------------------------------------
  t.colorBrandForegroundLink = accent
  t.colorBrandForegroundLinkHover = p.brandHover
  t.colorBrandForegroundLinkPressed = p.brandPressed
  t.colorBrandForegroundLinkSelected = accent
  t.colorNeutralForeground2Link = p.fg2
  t.colorNeutralForeground2LinkHover = fg
  t.colorNeutralForeground2LinkPressed = fg
  t.colorNeutralForeground2LinkSelected = fg
  t.colorCompoundBrandForeground1 = accent
  t.colorCompoundBrandForeground1Hover = p.brandHover
  t.colorCompoundBrandForeground1Pressed = p.brandPressed
  t.colorBrandForeground1 = accent
  t.colorBrandForeground2 = p.brandSoft
  t.colorBrandForeground2Hover = p.brandHover
  t.colorBrandForeground2Pressed = p.brandPressed
  t.colorBrandForegroundInverted = accent
  t.colorBrandForegroundInvertedHover = p.brandHover
  t.colorBrandForegroundInvertedPressed = p.brandPressed
  t.colorBrandForegroundOnLight = accent
  t.colorBrandForegroundOnLightHover = p.brandHover
  t.colorBrandForegroundOnLightPressed = p.brandPressed
  t.colorBrandForegroundOnLightSelected = accent

  // --- neutral background --------------------------------------------------
  function surface(name, base) {
    t["colorNeutralBackground" + name] = base
    t["colorNeutralBackground" + name + "Hover"] = raise(base, 0.05)
    t["colorNeutralBackground" + name + "Pressed"] = raise(base, 0.09)
    t["colorNeutralBackground" + name + "Selected"] = raise(base, 0.07)
  }
  surface("1", bg)
  surface("2", p.bg2)
  surface("3", p.bg3)
  surface("4", p.bg4)
  surface("5", p.bg5)
  t.colorNeutralBackground6 = p.bg6
  surface("7", p.bg6)
  t.colorNeutralBackground8 = p.bg6
  t.colorNeutralBackgroundInverted = mix(fg, bg, 0.08)
  t.colorNeutralBackgroundInvertedHover = mix(fg, bg, 0.14)
  t.colorNeutralBackgroundInvertedPressed = mix(fg, bg, 0.2)
  t.colorNeutralBackgroundInvertedSelected = mix(fg, bg, 0.16)
  t.colorNeutralBackgroundStatic = raise(bg, 0.15)
  t.colorNeutralBackgroundAlpha = alpha(bg, 0.5)
  t.colorNeutralBackgroundAlpha2 = alpha(bg, 0.8)
  t.colorSubtleBackground = "transparent"
  t.colorSubtleBackgroundHover = alpha(fg, 0.08)
  t.colorSubtleBackgroundPressed = alpha(fg, 0.12)
  t.colorSubtleBackgroundSelected = p.selection
  t.colorSubtleBackgroundLightAlphaHover = alpha(fg, 0.08)
  t.colorSubtleBackgroundLightAlphaPressed = alpha(fg, 0.12)
  t.colorSubtleBackgroundLightAlphaSelected = "transparent"
  t.colorSubtleBackgroundInverted = "transparent"
  t.colorSubtleBackgroundInvertedHover = alpha(bg, 0.1)
  t.colorSubtleBackgroundInvertedPressed = alpha(bg, 0.3)
  t.colorSubtleBackgroundInvertedSelected = alpha(bg, 0.2)
  t.colorTransparentBackground = "transparent"
  t.colorTransparentBackgroundHover = alpha(fg, 0.06)
  t.colorTransparentBackgroundPressed = alpha(fg, 0.1)
  t.colorTransparentBackgroundSelected = alpha(fg, 0.08)
  t.colorNeutralBackgroundDisabled = raise(bg, 0.06)
  t.colorNeutralBackgroundDisabled2 = raise(bg, 0.03)
  t.colorNeutralBackgroundInvertedDisabled = alpha(bg, 0.1)
  t.colorNeutralStencil1 = raise(bg, 0.12)
  t.colorNeutralStencil2 = raise(bg, 0.06)
  t.colorNeutralStencil1Alpha = alpha(fg, 0.12)
  t.colorNeutralStencil2Alpha = alpha(fg, 0.06)
  t.colorBackgroundOverlay = "rgba(0, 0, 0, 0.5)"
  t.colorScrollbarOverlay = alpha(fg, 0.35)

  // --- brand background ----------------------------------------------------
  t.colorBrandBackground = accent
  t.colorBrandBackgroundHover = p.brandHover
  t.colorBrandBackgroundPressed = p.brandPressed
  t.colorBrandBackgroundSelected = p.brandHover
  t.colorCompoundBrandBackground = accent
  t.colorCompoundBrandBackgroundHover = p.brandHover
  t.colorCompoundBrandBackgroundPressed = p.brandPressed
  t.colorBrandBackgroundStatic = accent
  t.colorBrandBackground2 = mix(accent, bg, 0.82)
  t.colorBrandBackground2Hover = mix(accent, bg, 0.75)
  t.colorBrandBackground2Pressed = mix(accent, bg, 0.68)
  t.colorBrandBackground3Static = mix(accent, bg, 0.5)
  t.colorBrandBackground4Static = mix(accent, bg, 0.3)
  t.colorBrandBackgroundInverted = bg
  t.colorBrandBackgroundInvertedHover = mix(bg, accent, 0.1)
  t.colorBrandBackgroundInvertedPressed = mix(bg, accent, 0.2)
  t.colorBrandBackgroundInvertedSelected = mix(bg, accent, 0.15)
  t.colorNeutralCardBackground = p.card
  t.colorNeutralCardBackgroundHover = raise(p.card, 0.05)
  t.colorNeutralCardBackgroundPressed = raise(p.card, 0.09)
  t.colorNeutralCardBackgroundSelected = raise(p.card, 0.07)
  t.colorNeutralCardBackgroundDisabled = p.card

  // --- strokes -------------------------------------------------------------
  t.colorNeutralStrokeAccessible = mix(fg, bg, 0.45)
  t.colorNeutralStrokeAccessibleHover = mix(fg, bg, 0.35)
  t.colorNeutralStrokeAccessiblePressed = mix(fg, bg, 0.3)
  t.colorNeutralStrokeAccessibleSelected = accent
  t.colorNeutralStroke1 = mix(fg, bg, 0.74)
  t.colorNeutralStroke1Hover = mix(fg, bg, 0.66)
  t.colorNeutralStroke1Pressed = mix(fg, bg, 0.62)
  t.colorNeutralStroke1Selected = mix(fg, bg, 0.66)
  t.colorNeutralStroke2 = mix(fg, bg, 0.82)
  t.colorNeutralStroke3 = mix(fg, bg, 0.88)
  t.colorNeutralStroke4 = mix(fg, bg, 0.92)
  t.colorNeutralStroke4Hover = mix(fg, bg, 0.9)
  t.colorNeutralStroke4Pressed = mix(fg, bg, 0.88)
  t.colorNeutralStroke4Selected = mix(fg, bg, 0.9)
  t.colorNeutralStrokeSubtle = mix(fg, bg, 0.82)
  t.colorNeutralStrokeOnBrand = bg
  t.colorNeutralStrokeOnBrand2 = p.onBrand
  t.colorNeutralStrokeOnBrand2Hover = p.onBrand
  t.colorNeutralStrokeOnBrand2Pressed = p.onBrand
  t.colorNeutralStrokeOnBrand2Selected = p.onBrand
  t.colorBrandStroke1 = accent
  t.colorBrandStroke2 = mix(accent, bg, 0.5)
  t.colorBrandStroke2Hover = mix(accent, bg, 0.4)
  t.colorBrandStroke2Pressed = mix(accent, bg, 0.3)
  t.colorBrandStroke2Contrast = mix(accent, bg, 0.6)
  t.colorCompoundBrandStroke = accent
  t.colorCompoundBrandStrokeHover = p.brandHover
  t.colorCompoundBrandStrokePressed = p.brandPressed
  t.colorNeutralStrokeDisabled = mix(fg, bg, 0.85)
  t.colorNeutralStrokeDisabled2 = mix(fg, bg, 0.9)
  t.colorNeutralStrokeInvertedDisabled = alpha(bg, 0.4)
  t.colorTransparentStroke = "transparent"
  t.colorTransparentStrokeInteractive = "transparent"
  t.colorTransparentStrokeDisabled = "transparent"
  t.colorNeutralStrokeAlpha = alpha(fg, 0.1)
  t.colorNeutralStrokeAlpha2 = alpha(fg, 0.2)
  t.colorStrokeFocus1 = bg
  t.colorStrokeFocus2 = accent

  // --- status --------------------------------------------------------------
  function status(name, color, extraDanger) {
    t["colorStatus" + name + "Background1"] = mix(color, bg, 0.85)
    t["colorStatus" + name + "Background2"] = mix(color, bg, 0.7)
    t["colorStatus" + name + "Background3"] = color
    t["colorStatus" + name + "Foreground1"] = color
    t["colorStatus" + name + "Foreground2"] = mix(color, fg, 0.3)
    t["colorStatus" + name + "Foreground3"] = color
    t["colorStatus" + name + "ForegroundInverted"] = readableOn(color, [bg, fg, "#000000", "#ffffff"])
    t["colorStatus" + name + "BorderActive"] = color
    t["colorStatus" + name + "Border1"] = mix(color, bg, 0.6)
    t["colorStatus" + name + "Border2"] = color
    if (extraDanger) {
      t.colorStatusDangerBackground3Hover = p.dark ? mix(color, "#ffffff", 0.1) : mix(color, "#000000", 0.1)
      t.colorStatusDangerBackground3Pressed = p.dark ? mix(color, "#ffffff", 0.2) : mix(color, "#000000", 0.2)
    }
  }
  status("Success", p.green)
  status("Warning", p.yellow)
  status("Danger", p.red, true)

  return t
}

// Border radii follow Hyprland's decoration:rounding so a sharp-cornered theme
// yields a sharp Teams and a rounded one stays rounded.
function radii(rounding) {
  if (typeof rounding !== "number" || !isFinite(rounding) || rounding < 0) return {}
  var r = rounding
  function px(v) { return Math.max(0, Math.round(v)) + "px" }
  return {
    borderRadiusNone: "0",
    borderRadiusSmall: px(r * 0.35),
    borderRadiusMedium: px(r * 0.55),
    borderRadiusLarge: px(r * 0.75),
    borderRadiusXLarge: px(r),
    borderRadius2XLarge: px(r * 1.5),
    borderRadius3XLarge: px(r * 2),
    borderRadius4XLarge: px(r * 3),
    borderRadius5XLarge: px(r * 4),
    borderRadius6XLarge: px(r * 5)
  }
}

// The selector list carries every place Fluent defines its variables: the
// FluentProvider root elements (one per React tree, including portals for
// menus and dialogs) plus :root and body for anything Teams paints outside a
// provider. `!important` beats the provider's own inline declarations.
var SELECTOR = ':root, body, .fui-FluentProvider, [class*="fui-FluentProvider"]'

function buildCss(colors, opts) {
  opts = opts || {}
  var p = palette(colors)
  var t = tokens(p)
  var extra = radii(opts.rounding)
  for (var k in extra) t[k] = extra[k]
  if (opts.fontFamily) {
    t.fontFamilyBase = opts.fontFamily
    t.fontFamilyNumeric = opts.fontFamily
  }

  var lines = ["/* omateams: Omarchy theme (" + p.mode + ") */", SELECTOR + " {"]
  for (var name in t) lines.push("  --" + name + ": " + t[name] + " !important;")
  lines.push("}")
  lines.push("html, body { background-color: " + p.bg + " !important; color: " + p.fg + "; color-scheme: " + p.mode + "; }")
  if (opts.fontFamily) lines.push("body { font-family: var(--fontFamilyBase) !important; }")
  lines.push("* { scrollbar-color: " + alpha(p.fg, 0.3) + " transparent; scrollbar-width: thin; }")
  lines.push("::-webkit-scrollbar { width: 8px; height: 8px; }")
  lines.push("::-webkit-scrollbar-track { background: transparent; }")
  lines.push("::-webkit-scrollbar-thumb { background: " + alpha(p.fg, 0.25) + "; border-radius: 4px; }")
  lines.push("::-webkit-scrollbar-thumb:hover { background: " + alpha(p.fg, 0.4) + "; }")
  lines.push("::selection { background: " + alpha(p.accent, 0.35) + "; }")
  return lines.join("\n") + "\n"
}

// The page-side script. Injected at document creation into every frame; it
// installs the stylesheet as early as possible and exposes __omateamsApply so
// a theme switch can restyle the running page without a reload.
function pageScript(css) {
  return "(function () {\n"
    + "  var css = " + JSON.stringify(css) + ";\n"
    + "  function apply() {\n"
    + "    var el = document.getElementById('omateams-theme');\n"
    + "    if (!el) {\n"
    + "      el = document.createElement('style');\n"
    + "      el.id = 'omateams-theme';\n"
    + "      (document.head || document.documentElement).appendChild(el);\n"
    + "    }\n"
    + "    if (el.textContent !== css) el.textContent = css;\n"
    + "  }\n"
    + "  window.__omateamsApply = function (next) { css = String(next || ''); apply(); };\n"
    + "  if (document.documentElement) apply();\n"
    + "  document.addEventListener('DOMContentLoaded', apply);\n"
    + "})();\n"
}
