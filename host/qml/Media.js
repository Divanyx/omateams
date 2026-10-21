.pragma library

// Tells the host whether the page is in a call, and whether it shares the
// screen.
//
// Teams piles up state over a long session, and the host reloads a hidden
// page once it has grown too big (see Main.qml). A call keeps running with
// the window hidden, and a reload would drop it. The page is asked first: a
// microphone, camera or screen track that is still live means a call or a
// meeting is going on, whether or not anyone is speaking.
//
// Sharing the screen is where Teams can run away: twice a session went from
// a few GiB to over 40 within half an hour of starting a share, until the
// machine ran out of memory. So a share is announced on the console the
// moment it starts and ends, the host watches memory closely while it lasts,
// and it can end the share here, which leaves the call itself running.

var MARKER = "[omateams] sharing "

function pageScript() {
  return "(function () {\n"
    + "  if (window.__omateamsInCall || !navigator.mediaDevices) return;\n"
    + "  var marker = " + JSON.stringify(MARKER) + ";\n"
    + "  var tracks = [];\n"
    + "  var screens = [];\n"
    + "  function live(t) { return t.readyState === 'live'; }\n"
    + "  function announce() {\n"
    + "    screens = screens.filter(live);\n"
    + "    console.log(marker + (screens.length > 0 ? 'on' : 'off'));\n"
    + "  }\n"
    + "  function track(display, stream) {\n"
    + "    if (!stream || !stream.getTracks) return stream;\n"
    + "    var added = stream.getTracks();\n"
    + "    tracks = tracks.filter(live).concat(added);\n"
    + "    if (display) {\n"
    + "      added.forEach(function (t) {\n"
    + "        screens.push(t);\n"
    + "        t.addEventListener('ended', announce);\n"
    + "        var stop = t.stop;\n"
    + "        t.stop = function () { stop.apply(t, arguments); announce(); };\n"
    + "      });\n"
    + "      announce();\n"
    + "    }\n"
    + "    return stream;\n"
    + "  }\n"
    + "  ['getUserMedia', 'getDisplayMedia'].forEach(function (name) {\n"
    + "    var original = navigator.mediaDevices[name];\n"
    + "    if (typeof original !== 'function') return;\n"
    + "    var display = name === 'getDisplayMedia';\n"
    + "    navigator.mediaDevices[name] = function () {\n"
    + "      return original.apply(navigator.mediaDevices, arguments).then(function (s) { return track(display, s); });\n"
    + "    };\n"
    + "  });\n"
    + "  window.__omateamsInCall = function () {\n"
    + "    tracks = tracks.filter(live);\n"
    + "    return tracks.length > 0;\n"
    + "  };\n"
    + "  window.__omateamsSharing = function () {\n"
    + "    screens = screens.filter(live);\n"
    + "    return screens.length > 0;\n"
    + "  };\n"
    // Ending a track from the page does not fire 'ended' on it, so Teams is
    // told the way a browser's own \"Stop sharing\" button would tell it.
    + "  window.__omateamsStopSharing = function () {\n"
    + "    var stopped = screens.filter(live);\n"
    + "    stopped.forEach(function (t) { t.stop(); t.dispatchEvent(new Event('ended')); });\n"
    + "    return stopped.length;\n"
    + "  };\n"
    + "})();\n"
}
