.pragma library

// A deadline for sign-ins that ask for a passkey.
//
// QtWebEngine leaves the WebAuthn user experience to the application and only
// asks for one once an authenticator answers: there is no step for "insert
// your security key". A request nothing can serve -- no key plugged in, and
// Linux has no built-in authenticator at all -- therefore sits in Chromium for
// about two minutes with nothing on screen, and every later attempt on that
// page fails with "a request is already pending" until it is reloaded.
//
// So the request is given a deadline of its own. The abort travels into
// Chromium through the standard AbortSignal, which ends the request there
// rather than only letting go of it here, and the page sees the
// NotAllowedError every sign-in page already knows how to fall back from.
// A key that is present and answers is untouched: it is done long before.

var MARKER = "[omateams] webauthn-timeout"

function pageScript() {
  return "(function () {\n"
    + "  var marker = " + JSON.stringify(MARKER) + ";\n"
    + "  if (!window.PublicKeyCredential || !navigator.credentials) return;\n"
    + "  if (window.__omateamsWebAuth) return;\n"
    + "  window.__omateamsWebAuth = true;\n"
    + "  var MIN = 15000, MAX = 120000, GRACE = 3000;\n"
    + "  function wrap(name) {\n"
    + "    var original = navigator.credentials[name];\n"
    + "    if (typeof original !== 'function') return;\n"
    + "    navigator.credentials[name] = function (options) {\n"
    // Passwords, federated logins and the background passkey hint are none of
    // this guard's business; the last one is meant to stay open.
    + "      if (!options || !options.publicKey || options.mediation === 'conditional')\n"
    + "        return original.call(navigator.credentials, options);\n"
    + "      var controller = new AbortController();\n"
    + "      var caller = options.signal;\n"
    + "      if (caller) {\n"
    + "        if (caller.aborted) controller.abort(caller.reason);\n"
    + "        else caller.addEventListener('abort', function () { controller.abort(caller.reason); });\n"
    + "      }\n"
    + "      var wanted = Number(options.publicKey.timeout);\n"
    + "      var deadline = Math.min(MAX, Math.max(MIN, isFinite(wanted) && wanted > 0 ? wanted : 60000)) + GRACE;\n"
    + "      var timer = setTimeout(function () {\n"
    + "        console.warn(marker);\n"
    + "        controller.abort(new DOMException('No security key answered in time. Passkeys kept by"
    + " this device or by a phone cannot be used in this window.', 'NotAllowedError'));\n"
    + "      }, deadline);\n"
    + "      var copy = {};\n"
    + "      for (var key in options) copy[key] = options[key];\n"
    + "      copy.signal = controller.signal;\n"
    + "      return original.call(navigator.credentials, copy).then(\n"
    + "        function (result) { clearTimeout(timer); return result; },\n"
    + "        function (error) { clearTimeout(timer); throw error; });\n"
    + "    };\n"
    + "  }\n"
    + "  wrap('get');\n"
    + "  wrap('create');\n"
    + "})();\n"
}
