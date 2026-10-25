(() => {
  "use strict";

  const DEFAULT_FONT_SIZE = 14;
  const DEFAULT_SCROLLBACK = 5000;
  const MAX_SCROLLBACK = 5000;
  const MAX_OUTPUT_BYTES = 32 * 1024;
  const MAX_INPUT_BYTES = 1024 * 1024;
  const MAX_PENDING_OUTPUT_BYTES = 1024 * 1024;
  const MAX_MESSAGE_LENGTH = 1500000;
  const encoder = new TextEncoder();
  const terminalHost = document.getElementById("terminal");

  let term = null;
  let fitAddon = null;
  let helperTextarea = null;
  let context = null;
  let currentInputEpoch = 0;
  let eventCounter = 0;
  let lifecycle = 0;
  let outputQueue = [];
  let queuedOutputBytes = 0;
  let activeWrite = null;
  let resetAfterWrite = false;
  let outputFailed = false;
  let lastOutputSeq = null;
  let suppressXtermInput = false;

  function isEpoch(value) {
    return Number.isSafeInteger(value) && value >= 0;
  }

  function isIdentifier(value) {
    return (
      (typeof value === "string" && value.length > 0 && value.length <= 128) ||
      (typeof value === "number" && Number.isSafeInteger(value))
    );
  }

  function identityFields(target) {
    return target
      ? {
          sessionId: target.sessionId,
          connectionEpoch: target.connectionEpoch,
          terminalGeneration: target.terminalGeneration,
        }
      : {};
  }

  function post(message) {
    const bridge = window.HTerminalBridge;
    if (!bridge || typeof bridge.postMessage !== "function") {
      return false;
    }
    try {
      bridge.postMessage(JSON.stringify(message));
      return true;
    } catch {
      return false;
    }
  }

  function reportError(code, target = context, fatal = false) {
    post({ type: "error", code, fatal, ...identityFields(target) });
  }

  function postReady() {
    post({ type: "ready", protocolVersion: 1, ...identityFields(context) });
  }

  function sameIdentity(a, b) {
    return (
      a &&
      b &&
      a.sessionId === b.sessionId &&
      a.connectionEpoch === b.connectionEpoch &&
      a.terminalGeneration === b.terminalGeneration
    );
  }

  function matchesCurrentContext(message, required) {
    if (!context) {
      return false;
    }
    for (const field of ["sessionId", "connectionEpoch", "terminalGeneration"]) {
      if (required && message[field] === undefined) {
        return false;
      }
      if (message[field] !== undefined && message[field] !== context[field]) {
        return false;
      }
    }
    return true;
  }

  function base64Encode(bytes) {
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 32768) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + 32768));
    }
    return btoa(binary);
  }

  function base64Decode(data, maximumBytes) {
    if (
      typeof data !== "string" ||
      data.length % 4 !== 0 ||
      data.length > Math.ceil(maximumBytes / 3) * 4 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(
        data,
      )
    ) {
      throw new Error("Invalid base64");
    }
    const binary = atob(data);
    if (binary.length > maximumBytes) {
      throw new Error("Payload too large");
    }
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  }

  function nextEventId() {
    eventCounter += 1;
    return `web:${context ? context.terminalGeneration : 0}:${eventCounter}`;
  }

  function sendInput(bytes, encoding, source, inputEpoch, eventId) {
    if (!context || !isEpoch(inputEpoch) || !isIdentifier(eventId)) {
      return false;
    }
    return post({
      type: "input",
      ...identityFields(context),
      inputEpoch,
      eventId,
      source,
      encoding,
      byteLength: bytes.byteLength,
      data: base64Encode(bytes),
    });
  }

  function sendCopy(inputEpoch, eventId) {
    if (!term || !context || !term.hasSelection()) {
      return;
    }
    const bytes = encoder.encode(term.getSelection());
    post({
      type: "copy",
      ...identityFields(context),
      inputEpoch,
      eventId,
      encoding: "utf8",
      byteLength: bytes.byteLength,
      data: base64Encode(bytes),
    });
  }

  function requestPaste(inputEpoch, eventId) {
    if (!context) {
      return;
    }
    post({
      type: "pasteRequest",
      ...identityFields(context),
      inputEpoch,
      eventId,
    });
  }

  function localShortcut(key, ctrl, alt, shift) {
    if (!ctrl || !shift || alt || typeof key !== "string") {
      return null;
    }
    const normalized = key.toLowerCase();
    if (normalized === "c") {
      return "copy";
    }
    if (normalized === "v") {
      return "paste";
    }
    return null;
  }

  function runLocalAction(action, inputEpoch, eventId) {
    if (action === "copy") {
      sendCopy(inputEpoch, eventId);
    } else if (action === "paste") {
      requestPaste(inputEpoch, eventId);
    }
  }

  function modifierCode(ctrl, alt, shift) {
    return 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
  }

  function encodeCursorKey(finalCharacter, ctrl, alt, shift) {
    const modifier = modifierCode(ctrl, alt, shift);
    if (modifier !== 1) {
      return `\x1b[1;${modifier}${finalCharacter}`;
    }
    return `${term.modes.applicationCursorKeysMode ? "\x1bO" : "\x1b["}${finalCharacter}`;
  }

  function encodeTildeKey(number, ctrl, alt, shift) {
    const modifier = modifierCode(ctrl, alt, shift);
    return modifier === 1
      ? `\x1b[${number}~`
      : `\x1b[${number};${modifier}~`;
  }

  function encodeFunctionKey(number, ctrl, alt, shift) {
    const modifier = modifierCode(ctrl, alt, shift);
    if (number <= 4) {
      const finalCharacter = "PQRS"[number - 1];
      return modifier === 1
        ? `\x1bO${finalCharacter}`
        : `\x1b[1;${modifier}${finalCharacter}`;
    }
    const codes = { 5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24 };
    return encodeTildeKey(codes[number], ctrl, alt, shift);
  }

  function encodeControlCharacter(key) {
    const lower = key.toLowerCase();
    if (/^[a-z]$/.test(lower)) {
      return String.fromCharCode(lower.charCodeAt(0) - 96);
    }
    const controls = {
      "@": 0,
      " ": 0,
      "2": 0,
      "[": 27,
      "3": 27,
      "\\": 28,
      "4": 28,
      "]": 29,
      "5": 29,
      "^": 30,
      "6": 30,
      "_": 31,
      "7": 31,
      "/": 31,
      "?": 127,
      "8": 127,
    };
    return Object.hasOwn(controls, key)
      ? String.fromCharCode(controls[key])
      : null;
  }

  function encodeKey(key, ctrl, alt, shift) {
    const aliases = {
      Esc: "Escape",
      Return: "Enter",
      Spacebar: " ",
      Del: "Delete",
      Left: "ArrowLeft",
      Right: "ArrowRight",
      Up: "ArrowUp",
      Down: "ArrowDown",
    };
    const normalized = aliases[key] || key;
    const cursorKeys = {
      ArrowUp: "A",
      ArrowDown: "B",
      ArrowRight: "C",
      ArrowLeft: "D",
      Home: "H",
      End: "F",
    };
    const tildeKeys = { Insert: 2, Delete: 3, PageUp: 5, PageDown: 6 };

    if (Object.hasOwn(cursorKeys, normalized)) {
      return encodeCursorKey(cursorKeys[normalized], ctrl, alt, shift);
    }
    if (Object.hasOwn(tildeKeys, normalized)) {
      return encodeTildeKey(tildeKeys[normalized], ctrl, alt, shift);
    }
    if (/^F(?:[1-9]|1[0-2])$/.test(normalized)) {
      return encodeFunctionKey(Number(normalized.slice(1)), ctrl, alt, shift);
    }

    let encoded;
    switch (normalized) {
      case "Backspace":
        encoded = ctrl ? "\x08" : "\x7f";
        break;
      case "Enter":
        encoded = "\r";
        break;
      case "Tab":
        if (shift) {
          const modifier = modifierCode(ctrl, alt, true);
          return modifier === 2 ? "\x1b[Z" : `\x1b[1;${modifier}Z`;
        }
        encoded = "\t";
        break;
      case "Escape":
        encoded = "\x1b";
        break;
      case " ":
        encoded = ctrl ? "\x00" : " ";
        break;
      default:
        if (typeof normalized !== "string" || normalized.length === 0) {
          return null;
        }
        if (Array.from(normalized).length === 1) {
          if (ctrl) {
            encoded = encodeControlCharacter(normalized);
            if (encoded === null) {
              return null;
            }
          } else {
            encoded = shift && /^[a-z]$/.test(normalized)
              ? normalized.toUpperCase()
              : normalized;
          }
        } else {
          return null;
        }
    }
    return `${alt ? "\x1b" : ""}${encoded}`;
  }

  function configureTextarea(ime, shouldFocus) {
    if (!helperTextarea || !term) {
      return;
    }
    helperTextarea.blur();
    helperTextarea.readOnly = !ime;
    helperTextarea.setAttribute("inputmode", ime ? "text" : "none");
    helperTextarea.setAttribute("autocomplete", "off");
    helperTextarea.setAttribute("autocapitalize", "off");
    helperTextarea.setAttribute("autocorrect", "off");
    helperTextarea.setAttribute("spellcheck", "false");
    if (shouldFocus) {
      term.focus();
    }
  }

  function fitTerminal(sendResize) {
    if (!term || !fitAddon || !context) {
      return false;
    }
    if (terminalHost.clientWidth <= 0 || terminalHost.clientHeight <= 0) {
      return false;
    }
    const target = context;
    const token = lifecycle;
    try {
      fitAddon.fit();
    } catch {
      reportError("fit-failed", target);
      return false;
    }
    if (
      sendResize &&
      token === lifecycle &&
      sameIdentity(context, target) &&
      term.cols > 0 &&
      term.rows > 0
    ) {
      post({
        type: "resize",
        ...identityFields(target),
        cols: term.cols,
        rows: term.rows,
      });
    }
    return true;
  }

  function recreateTerminal(fontSize, scrollback) {
    if (term) {
      term.dispose();
    }
    term = null;
    fitAddon = null;
    helperTextarea = null;
    createTerminal(fontSize, scrollback);
  }

  function createTerminal(fontSize, scrollback) {
    const linkHandler = {
      allowNonHttpProtocols: false,
      activate(event) {
        event.preventDefault();
        event.stopPropagation();
      },
    };
    term = new window.Terminal({
      cursorBlink: true,
      fontFamily: "monospace",
      fontSize,
      linkHandler,
      scrollback,
    });
    fitAddon = new window.FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(terminalHost);
    helperTextarea = terminalHost.querySelector(".xterm-helper-textarea");
    configureTextarea(false, false);

    term.attachCustomKeyEventHandler((event) => {
      if (suppressXtermInput || resetAfterWrite) {
        event.preventDefault();
        event.stopPropagation();
        return false;
      }
      const action = localShortcut(
        event.key,
        event.ctrlKey,
        event.altKey || event.metaKey,
        event.shiftKey,
      );
      if (!action) {
        return true;
      }
      event.preventDefault();
      event.stopPropagation();
      if (event.type === "keydown" && !event.repeat && context) {
        runLocalAction(action, currentInputEpoch, nextEventId());
      }
      return false;
    });
    term.onData((data) => {
      if (!suppressXtermInput && context) {
        sendInput(
          encoder.encode(data),
          "utf8",
          "onData",
          currentInputEpoch,
          nextEventId(),
        );
      }
    });
    term.onBinary((data) => {
      if (suppressXtermInput || !context) {
        return;
      }
      const bytes = new Uint8Array(data.length);
      for (let index = 0; index < data.length; index += 1) {
        bytes[index] = data.charCodeAt(index) & 0xff;
      }
      sendInput(bytes, "binary", "onBinary", currentInputEpoch, nextEventId());
    });
  }

  function failOutput(code) {
    outputFailed = true;
    outputQueue = [];
    queuedOutputBytes = 0;
    reportError(code, context, true);
  }

  function acknowledge(frame) {
    post({
      type: "ack",
      ...identityFields(frame.context),
      seq: frame.seq,
      byteLength: frame.byteLength,
    });
  }

  function pumpOutput() {
    if (
      !term ||
      !context ||
      activeWrite ||
      resetAfterWrite ||
      outputFailed ||
      outputQueue.length === 0
    ) {
      return;
    }
    const frame = outputQueue.shift();
    queuedOutputBytes -= frame.byteLength;
    activeWrite = frame;
    try {
      term.write(frame.bytes, () => {
        if (activeWrite === frame) {
          activeWrite = null;
        }
        if (frame.lifecycle === lifecycle && !outputFailed) {
          acknowledge(frame);
        }
        if (resetAfterWrite && !activeWrite) {
          resetAfterWrite = false;
          recreateTerminal(term.options.fontSize, term.options.scrollback);
          fitTerminal(true);
          suppressXtermInput = false;
          postReady();
        }
        pumpOutput();
      });
    } catch {
      if (activeWrite === frame) {
        activeWrite = null;
      }
      failOutput("write-failed");
    }
  }

  function handleInit(message) {
    if (
      !isIdentifier(message.sessionId) ||
      !isEpoch(message.connectionEpoch) ||
      !isEpoch(message.terminalGeneration) ||
      (message.inputEpoch !== undefined && !isEpoch(message.inputEpoch)) ||
      (message.fontSize !== undefined &&
        (typeof message.fontSize !== "number" ||
          !Number.isFinite(message.fontSize) ||
          message.fontSize <= 0 ||
          message.fontSize > 72)) ||
      (message.scrollback !== undefined &&
        (!Number.isSafeInteger(message.scrollback) || message.scrollback < 0))
    ) {
      return false;
    }

    const fontSize = message.fontSize ?? DEFAULT_FONT_SIZE;
    const scrollback = Math.min(
      message.scrollback ?? DEFAULT_SCROLLBACK,
      MAX_SCROLLBACK,
    );
    if (!term) {
      createTerminal(fontSize, scrollback);
    }

    const nextContext = {
      sessionId: message.sessionId,
      connectionEpoch: message.connectionEpoch,
      terminalGeneration: message.terminalGeneration,
    };
    const identityChanged = !sameIdentity(context, nextContext);
    if (identityChanged) {
      lifecycle += 1;
      suppressXtermInput = true;
      outputQueue = [];
      queuedOutputBytes = 0;
      lastOutputSeq = null;
      outputFailed = false;
      currentInputEpoch = message.inputEpoch ?? 0;
      context = nextContext;
      resetAfterWrite = Boolean(activeWrite);
      if (!resetAfterWrite) {
        recreateTerminal(fontSize, scrollback);
        suppressXtermInput = false;
      }
    } else {
      context = nextContext;
      if (message.inputEpoch !== undefined) {
        currentInputEpoch = message.inputEpoch;
      }
    }

    term.options.fontSize = fontSize;
    term.options.scrollback = scrollback;
    if (!resetAfterWrite) {
      fitTerminal(true);
      postReady();
    }
    return true;
  }

  function handleOutput(message) {
    if (
      !matchesCurrentContext(message, true) ||
      outputFailed ||
      !isEpoch(message.seq) ||
      !isEpoch(message.byteLength) ||
      message.byteLength > MAX_OUTPUT_BYTES ||
      (lastOutputSeq !== null && message.seq !== lastOutputSeq + 1)
    ) {
      return false;
    }

    let bytes;
    try {
      bytes = base64Decode(message.data, MAX_OUTPUT_BYTES);
    } catch {
      failOutput("invalid-output");
      return false;
    }
    if (bytes.byteLength !== message.byteLength) {
      failOutput("output-length-mismatch");
      return false;
    }
    const activeBytes =
      activeWrite && activeWrite.lifecycle === lifecycle
        ? activeWrite.byteLength
        : 0;
    if (queuedOutputBytes + activeBytes + bytes.byteLength > MAX_PENDING_OUTPUT_BYTES) {
      failOutput("output-overflow");
      return false;
    }

    const frame = {
      bytes,
      byteLength: bytes.byteLength,
      context: { ...context },
      lifecycle,
      seq: message.seq,
    };
    lastOutputSeq = message.seq;
    outputQueue.push(frame);
    queuedOutputBytes += bytes.byteLength;
    pumpOutput();
    return true;
  }

  function validateInputMessage(message) {
    return (
      matchesCurrentContext(message, false) &&
      isEpoch(message.inputEpoch) &&
      isIdentifier(message.eventId)
    );
  }

  function handleKey(message) {
    if (!validateInputMessage(message) || typeof message.key !== "string") {
      return false;
    }
    const ctrl = message.ctrl === true;
    const alt = message.alt === true;
    const shift = message.shift === true;
    const action = localShortcut(message.key, ctrl, alt, shift);
    currentInputEpoch = message.inputEpoch;
    if (action) {
      runLocalAction(action, message.inputEpoch, message.eventId);
      return true;
    }
    const encoded = encodeKey(message.key, ctrl, alt, shift);
    if (encoded === null) {
      return false;
    }
    return sendInput(
      encoder.encode(encoded),
      "utf8",
      "key",
      message.inputEpoch,
      message.eventId,
    );
  }

  function decodeInputPayload(message) {
    if (
      message.byteLength !== undefined &&
      !isEpoch(message.byteLength)
    ) {
      throw new Error("Invalid byte length");
    }
    const bytes = base64Decode(message.data, MAX_INPUT_BYTES);
    if (
      message.byteLength !== undefined &&
      message.byteLength !== bytes.byteLength
    ) {
      throw new Error("Input length mismatch");
    }
    return bytes;
  }

  function handleText(message) {
    if (!validateInputMessage(message)) {
      return false;
    }
    try {
      const bytes = decodeInputPayload(message);
      currentInputEpoch = message.inputEpoch;
      if (bytes.byteLength === 0) {
        return true;
      }
      return sendInput(
        bytes,
        "utf8",
        "text",
        message.inputEpoch,
        message.eventId,
      );
    } catch {
      return false;
    }
  }

  function handlePaste(message) {
    if (!validateInputMessage(message)) {
      return false;
    }
    try {
      const bytes = decodeInputPayload(message);
      currentInputEpoch = message.inputEpoch;
      if (bytes.byteLength === 0 && !term.modes.bracketedPasteMode) {
        return true;
      }
      let payload = bytes;
      if (term.modes.bracketedPasteMode) {
        const start = encoder.encode("\x1b[200~");
        const end = encoder.encode("\x1b[201~");
        payload = new Uint8Array(start.length + bytes.length + end.length);
        payload.set(start, 0);
        payload.set(bytes, start.length);
        payload.set(end, start.length + bytes.length);
      }
      return sendInput(
        payload,
        "utf8",
        "paste",
        message.inputEpoch,
        message.eventId,
      );
    } catch {
      return false;
    }
  }

  function receive(jsonString) {
    if (typeof jsonString !== "string" || jsonString.length > MAX_MESSAGE_LENGTH) {
      return false;
    }
    let message;
    try {
      message = JSON.parse(jsonString);
    } catch {
      return false;
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      return false;
    }
    if (resetAfterWrite && ["key", "text", "paste", "copy", "fit", "focus", "clear"].includes(message.type)) {
      return false;
    }

    try {
      switch (message.type) {
        case "init":
          return handleInit(message);
        case "output":
          return handleOutput(message);
        case "key":
          return handleKey(message);
        case "text":
          return handleText(message);
        case "paste":
          return handlePaste(message);
        case "copy":
          if (!matchesCurrentContext(message, false)) {
            return false;
          }
          sendCopy(currentInputEpoch, nextEventId());
          return true;
        case "fit":
          return matchesCurrentContext(message, false) && fitTerminal(true);
        case "focus":
          if (!matchesCurrentContext(message, false) || typeof message.ime !== "boolean") {
            return false;
          }
          if (message.inputEpoch !== undefined) {
            if (!isEpoch(message.inputEpoch)) {
              return false;
            }
            currentInputEpoch = message.inputEpoch;
          }
          configureTextarea(message.ime, true);
          return true;
        case "clear":
          if (!matchesCurrentContext(message, false)) {
            return false;
          }
          term.clear();
          return true;
        default:
          return false;
      }
    } catch {
      reportError("message-error");
      return false;
    }
  }

  document.addEventListener(
    "click",
    (event) => {
      const target = event.target;
      if (target && typeof target.closest === "function" && target.closest("a")) {
        event.preventDefault();
        event.stopPropagation();
      }
    },
    true,
  );
  for (const type of ["submit", "dragover", "drop"]) {
    document.addEventListener(type, (event) => event.preventDefault(), true);
  }
  terminalHost.addEventListener("paste", (event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
    if (!suppressXtermInput && context) {
      requestPaste(currentInputEpoch, nextEventId());
    }
  }, true);
  window.open = () => null;
  window.HTerminal = Object.freeze({ receive });
})();
