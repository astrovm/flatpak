// A cat that chases the cursor (or your finger) and gets up to mischief when bored.
// Based on oneko.js by adryd325 (MIT).
//
// Rub it with the mouse to make it purr. Select some text and it may come paw at it.
// Secrets: type "pspsps" to call it, "nyan" for a rainbow run or "fish" for a treat.
// From the console: oneko.bite(), knock(), push(), steal(), perch(), scratch(),
// peek(), nap(), hunt(), box(), pounce(), treat(), pspsps(), nyan(), friend(),
// pet(), play() and hat("pumpkin").
// Add ?today=2026-10-31T03:00 to the URL to pretend it is another day or time.
// Put data-oneko-home on an element and the cat naps there until someone clicks it.
(function oneko() {
  const SIZE = 32;
  const TICK = 100;
  const SPEED = 10;
  const HEAL_AFTER = 30000;
  const MAX_BITES = 3;
  const PINK = "#f462c6";

  // Solid things, so bites and shoves show: pictures, cards, buttons, code, the logo.
  const SOLID = [
    "img",
    "pre",
    "figure",
    ".app-card",
    ".app-screenshot",
    ".project-card",
    ".button",
    ".terminal",
    ".logo",
    ".header-link",
    ".post-title",
  ].join(", ");
  const PICTURES = "img";
  const WORDY = "main p, .post-content p, .index-content p, .lede, .project-description";
  const PERCHES = "#install-link, .app-card-cta, .read-more";
  const MEOWS = ["nya~", "mrrp?", "(=^･ω･^=)", "ฅ^•ﻌ•^ฅ", "meow", "=^.^="];

  const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const touch = !window.matchMedia("(pointer: fine)").matches;
  // A plain date means noon that day here, not midnight in London.
  const asked = new URLSearchParams(window.location.search).get("today");
  const pretend = asked && /^\d{4}-\d{2}-\d{2}$/.test(asked) ? `${asked}T12:00` : asked;
  const today = pretend && !Number.isNaN(Date.parse(pretend)) ? new Date(pretend) : new Date();
  const lateNight = today.getHours() >= 1 && today.getHours() < 6;
  const catDay = today.getMonth() === 7 && today.getDate() === 8;

  const spriteSets = {
    idle: [[-3, -3]],
    alert: [[-7, -3]],
    scratchSelf: [
      [-5, 0],
      [-6, 0],
      [-7, 0],
    ],
    scratchWallN: [
      [0, 0],
      [0, -1],
    ],
    scratchWallS: [
      [-7, -1],
      [-6, -2],
    ],
    scratchWallE: [
      [-2, -2],
      [-2, -3],
    ],
    scratchWallW: [
      [-4, 0],
      [-4, -1],
    ],
    tired: [[-3, -2]],
    sleeping: [
      [-2, 0],
      [-2, -1],
    ],
    N: [
      [-1, -2],
      [-1, -3],
    ],
    NE: [
      [0, -2],
      [0, -3],
    ],
    E: [
      [-3, 0],
      [-3, -1],
    ],
    SE: [
      [-5, -1],
      [-5, -2],
    ],
    S: [
      [-6, -3],
      [-7, -2],
    ],
    SW: [
      [-5, -3],
      [-6, -1],
    ],
    W: [
      [-4, -2],
      [-4, -3],
    ],
    NW: [
      [-1, 0],
      [-1, -1],
    ],
  };

  const cats = [];
  let pointer = null;
  let lastPointerAt = 0;
  let nyanUntil = 0;
  let yarn = null;
  let hat = null;
  let home = document.querySelector("[data-oneko-home]");
  const reading = () => location.pathname.includes("/blog/") && Boolean(document.querySelector(".post:not(.on-list) .post-content"));
  let readingScrollAt = 0;
  window.addEventListener("scroll", () => { readingScrollAt = Date.now(); }, { passive: true });
  const progressSpot = () => {
    const max = document.documentElement.scrollHeight - window.innerHeight;
    const done = max > 0 ? Math.min(1, window.scrollY / max) : 1;
    return { x: Math.max(16, Math.min(window.innerWidth - 16, done * window.innerWidth - 12)), y: 19 };
  };
  let invitedUntil = 0;
  const quiet = () => reading() && Date.now() > invitedUntil;
  const invite = () => { invitedUntil = Date.now() + 15000; };
  let parked = Boolean(home);
  let butterfly = null;
  const treats = [];

  const random = (list) => list[Math.floor(Math.random() * list.length)];
  const between = (min, max) => min + Math.random() * (max - min);

  // The cat remembers you between visits.
  const memory = {
    get(key, fallback) {
      try {
        const value = localStorage.getItem(`oneko.${key}`);
        return value === null ? fallback : JSON.parse(value);
      } catch {
        return fallback;
      }
    },
    set(key, value) {
      try {
        localStorage.setItem(`oneko.${key}`, JSON.stringify(value));
      } catch {
        // Private mode: the cat forgets, which is fine.
      }
    },
  };

  // Every pet counts. Some numbers are special, and 100 earns a crown.
  function countPet() {
    const pets = memory.get("pets", 0) + 1;
    memory.set("pets", pets);
    if (pets === 100 && !hat) {
      setHat("crown");
    }
    return { 10: "we're friends now ♡", 50: "best friends ♡", 100: "i'm royalty now ♛" }[pets];
  }

  function onScreen(rect, margin = 8) {
    return (
      rect.width > 0 &&
      rect.top > 24 &&
      rect.bottom < window.innerHeight - margin &&
      rect.left > margin &&
      rect.right < window.innerWidth - margin
    );
  }

  function visible(selector, test = () => true, whole = true) {
    return [...document.querySelectorAll(selector)].filter((el) => {
      const rect = el.getBoundingClientRect();
      return (!whole || onScreen(rect)) && test(el, rect);
    });
  }

  // Little things that float or fall and then disappear.

  function addStyles() {
    const style = document.createElement("style");
    style.textContent = `
      .oneko-cat { position: fixed; z-index: 2147483647; width: ${SIZE}px; height: ${SIZE}px;
        background-image: url("/oneko.gif"); image-rendering: pixelated; touch-action: manipulation; }
      .oneko-bitten { animation: oneko-shake 300ms ease; }
      @keyframes oneko-shake { 25% { translate: -2px 0; } 75% { translate: 2px 0; } }
      .oneko-bit, .oneko-bubble, .oneko-loot { position: fixed; z-index: 2147483646;
        pointer-events: none; font: 700 13px/1.2 monospace; white-space: nowrap; }
      .oneko-bit { animation: oneko-fall 700ms ease-in forwards; }
      .oneko-heart, .oneko-z { color: ${PINK}; animation-name: oneko-float; animation-duration: 1200ms; }
      @keyframes oneko-fall { to { translate: var(--dx) 28px; opacity: 0; } }
      @keyframes oneko-float { to { translate: var(--dx) -32px; opacity: 0; } }
      .oneko-bubble { translate: -50% 0; padding: 3px 7px; border: 2px solid ${PINK};
        background: #211f2b; color: #eceae5; animation: oneko-pop 2200ms ease forwards; }
      @keyframes oneko-pop { 0% { scale: 0.6; opacity: 0; } 10%, 85% { scale: 1; opacity: 1; } 100% { opacity: 0; } }
      .oneko-loot { translate: -50% 0; padding: 0 3px; background: ${PINK}; color: #211f2b; }
      .oneko-print, .oneko-rainbow, .oneko-claws { position: absolute; z-index: 2147483645; pointer-events: none; }
      .oneko-print { width: 10px; height: 10px; opacity: 0.45; animation: oneko-fade 4s linear forwards;
        background: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 20' fill='%23f462c6'%3E%3Cellipse cx='10' cy='13' rx='5' ry='4.5'/%3E%3Ccircle cx='4' cy='7' r='2.2'/%3E%3Ccircle cx='8' cy='4' r='2.2'/%3E%3Ccircle cx='12' cy='4' r='2.2'/%3E%3Ccircle cx='16' cy='7' r='2.2'/%3E%3C/svg%3E") center / contain no-repeat; }
      .oneko-rainbow { width: 14px; height: 18px; animation: oneko-fade 1200ms linear forwards;
        background: linear-gradient(#ff3b3b 0 17%, #ff9f1a 0 33%, #ffe14d 0 50%, #4cd964 0 67%, #3ba7ff 0 83%, #a45bff 0); }
      .oneko-claws { width: 22px; height: 26px; animation: oneko-fade 12s ease-in forwards;
        background: repeating-linear-gradient(115deg, transparent 0 4px, rgb(236 234 229 / 55%) 4px 6px, transparent 6px 9px); }
      @keyframes oneko-fade { to { opacity: 0; } }
      .oneko-yarn { position: fixed; z-index: 2147483646; width: 24px; height: 24px; touch-action: none;
        cursor: grab; border-radius: 50%; translate: -50% -50%;
        background: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Ccircle cx='12' cy='12' r='11' fill='%23f462c6'/%3E%3Cg fill='none' stroke='%23211f2b' stroke-width='1.3' opacity='.55'%3E%3Cpath d='M3 9c6-2 12-2 18 1M2.5 14c7-3 13-3 19 0M6 20c3-6 8-12 13-15M5 5c5 2 9 8 10 17'/%3E%3C/g%3E%3C/svg%3E") center / contain; }
      .oneko-yarn:active { cursor: grabbing; }
      .oneko-hat { position: absolute; left: 50%; top: -9px; width: 20px; height: 14px; translate: -50% 0;
        pointer-events: none; background: center bottom / contain no-repeat; }
      .oneko-hat-pumpkin { background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 14'%3E%3Cpath d='M10 3c1-2 2-3 3-3' stroke='%2333691e' stroke-width='1.6' fill='none'/%3E%3Cellipse cx='6.5' cy='9' rx='5' ry='4.6' fill='%23e8710a'/%3E%3Cellipse cx='13.5' cy='9' rx='5' ry='4.6' fill='%23e8710a'/%3E%3Cellipse cx='10' cy='9' rx='4.4' ry='4.8' fill='%23ff8c1a'/%3E%3C/svg%3E"); }
      .oneko-hat-santa { width: 22px; height: 15px; background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 22 15'%3E%3Cpath d='M3 12C5 4 11 0 17 3l2 6' fill='%23d62828'/%3E%3Crect x='1' y='11' width='18' height='4' rx='2' fill='%23fff'/%3E%3Ccircle cx='19' cy='9' r='2.4' fill='%23fff'/%3E%3C/svg%3E"); }
      .oneko-fish, .oneko-box, .oneko-butterfly { position: fixed; z-index: 2147483646; pointer-events: none;
        background: center / contain no-repeat; }
      .oneko-fish { width: 20px; height: 12px; translate: -50% -50%;
        animation: oneko-drop 700ms cubic-bezier(.5,0,1,.5), oneko-land 300ms 700ms ease-out;
        background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 12'%3E%3Cpath d='M0 1l6 5-6 5z' fill='%235fb4e8'/%3E%3Cellipse cx='12' cy='6' rx='8' ry='5' fill='%237cc8f5'/%3E%3Ccircle cx='16' cy='5' r='1.2' fill='%23211f2b'/%3E%3C/svg%3E"); }
      @keyframes oneko-drop { from { translate: -50% calc(-50% - var(--fall)); } }
      @keyframes oneko-land { 50% { translate: -50% calc(-50% - 6px); } }
      .oneko-box { z-index: 2147483647; width: 34px; height: 22px; translate: -50% 0;
        transform-origin: bottom; animation: oneko-box-in 300ms cubic-bezier(.3,1.6,.6,1);
        background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 34 22'%3E%3Cg stroke='%236b4423'%3E%3Cpath d='M3 7h28v14H3z' fill='%23c68a4e'/%3E%3Cpath d='M3 7 .5 2h9L12 7zm28 0 2.5-5h-9L22 7z' fill='%23d9a066'/%3E%3C/g%3E%3Cpath d='M3.5 7.5h27v2h-27z' fill='%238a5a2b'/%3E%3C/svg%3E"); }
      @keyframes oneko-box-in { from { scale: 0.3; opacity: 0; } }
      .oneko-box-gone { transition: opacity 400ms ease, translate 400ms ease; opacity: 0; translate: -50% 8px; }
      .oneko-butterfly { width: 16px; height: 14px; translate: -50% -50%;
        animation: oneko-flutter 160ms ease-in-out infinite alternate;
        background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 14'%3E%3Cellipse cx='4.5' cy='5' rx='4' ry='4.5' fill='%23f462c6'/%3E%3Cellipse cx='11.5' cy='5' rx='4' ry='4.5' fill='%23f462c6'/%3E%3Cellipse cx='5' cy='11' rx='3' ry='2.5' fill='%23ffa8e4'/%3E%3Cellipse cx='11' cy='11' rx='3' ry='2.5' fill='%23ffa8e4'/%3E%3Crect x='7.3' y='2' width='1.4' height='11' rx='.7' fill='%23211f2b'/%3E%3C/svg%3E"); }
      @keyframes oneko-flutter { to { scale: 0.35 1; } }
      .oneko-hat-crown { background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 14'%3E%3Cpath d='M2 13 1 3l5 4 4-6 4 6 5-4-1 10z' fill='%23ffcc00' stroke='%23b8860b' stroke-width='1'/%3E%3C/svg%3E"); }
    `;
    document.head.appendChild(style);
  }

  function puff(text, className, px, py, dx = "0px") {
    const bit = document.createElement("span");
    bit.className = `oneko-bit ${className}`.trim();
    bit.textContent = text;
    bit.style.left = `${px - 4}px`;
    bit.style.top = `${py - 8}px`;
    bit.style.setProperty("--dx", dx);
    document.body.appendChild(bit);
    setTimeout(() => bit.remove(), 1300);
  }

  function crumbs(cx, cy) {
    for (let i = 0; i < 4; i += 1) {
      puff("·", "", cx, cy, `${between(-15, 15)}px`);
    }
  }

  // Marks left on the page itself, so they scroll with it.
  function mark(className, px, py, angle = 0, life = 4000) {
    const el = document.createElement("span");
    el.className = className;
    el.style.left = `${px + window.scrollX}px`;
    el.style.top = `${py + window.scrollY}px`;
    el.style.rotate = `${angle}deg`;
    document.body.appendChild(el);
    setTimeout(() => el.remove(), life);
  }

  // Bites: cartoon chunks cut out of an element's edge.

  function chomp(el, bx, by) {
    const radius = Math.max(7, Math.min(14, el.getBoundingClientRect().height / 3));
    const bites = (el.onekoBites = el.onekoBites || []);
    const bite = { bx, by, radius };
    bites.push(bite);
    paintBites(el);
    el.classList.remove("oneko-bitten");
    void el.offsetWidth;
    el.classList.add("oneko-bitten");
    setTimeout(() => {
      bites.splice(bites.indexOf(bite), 1);
      paintBites(el);
    }, HEAL_AFTER);
  }

  function paintBites(el) {
    const holes = el.onekoBites.flatMap(({ bx, by, radius }) =>
      [-0.8, 0, 0.8].map(
        (shift) =>
          `radial-gradient(circle ${radius}px at ${bx + shift * radius}px ${by + Math.abs(shift) * 2}px, transparent 98%, #000 100%)`,
      ),
    );
    el.style.maskImage = holes.join(", ");
    el.style.webkitMaskImage = holes.join(", ");
    el.style.maskComposite = holes.map(() => "intersect").join(", ");
    el.style.webkitMaskComposite = holes.map(() => "source-in").join(", ");
  }

  function tilt(el, degrees) {
    el.style.transition = "rotate 300ms cubic-bezier(.3,1.6,.6,1)";
    el.style.rotate = `${degrees}deg`;
    setTimeout(() => {
      el.style.rotate = "";
    }, HEAL_AFTER);
  }

  function shove(el, direction) {
    el.onekoShoved = true;
    el.style.transition = "translate 1.4s cubic-bezier(.5,0,.9,.4), rotate 1.4s ease-in";
    el.style.translate = `${direction * window.innerWidth}px 40px`;
    el.style.rotate = `${direction * 30}deg`;
    setTimeout(() => {
      el.style.transition = "translate 800ms cubic-bezier(.2,1.3,.5,1), rotate 800ms ease";
      el.style.translate = "";
      el.style.rotate = "";
      el.onekoShoved = false;
    }, HEAL_AFTER);
  }

  // Pick a word in a paragraph and wrap it, so the cat can carry it off.
  function pickWord() {
    for (const paragraph of visible(WORDY).sort(() => Math.random() - 0.5)) {
      const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
      const words = [];
      while (walker.nextNode()) {
        const node = walker.currentNode;
        if (node.parentElement.closest(".oneko-word")) {
          continue;
        }
        for (const match of node.textContent.matchAll(/\p{L}{4,}/gu)) {
          words.push({ node, start: match.index, end: match.index + match[0].length });
        }
      }
      if (words.length > 0) {
        const { node, start, end } = random(words);
        const range = document.createRange();
        range.setStart(node, start);
        range.setEnd(node, end);
        const word = document.createElement("span");
        word.className = "oneko-word";
        range.surroundContents(word);
        return word;
      }
    }
    return null;
  }

  // The cats.

  class Cat {
    constructor(x, y, leader = null) {
      this.x = x;
      this.y = y;
      this.leader = leader;
      this.frameCount = 0;
      this.idleTime = 0;
      this.idleAnimation = null;
      this.idleAnimationFrame = 0;
      this.plan = null;
      this.loot = null;
      this.clicks = 0;
      this.purrUntil = 0;
      this.el = document.createElement("div");
      this.el.className = "oneko-cat";
      this.el.setAttribute("aria-hidden", "true");
      this.hatEl = document.createElement("span");
      this.el.appendChild(this.hatEl);
      this.wearHat();
      this.el.addEventListener("click", (event) => {
        event.stopPropagation();
        if (this.suppressClick) { this.suppressClick = false; return; }
        this.petted();
      });
      this.listenForRubs();
      this.listenForDrag();
      document.body.appendChild(this.el);
      this.place();
      this.setSprite("idle", 0);
    }

    wearHat() {
      this.hatEl.className = hat ? `oneko-hat oneko-hat-${hat}` : "";
    }

    place() {
      this.el.style.left = `${this.x - SIZE / 2}px`;
      this.el.style.top = `${this.y - SIZE / 2}px`;
      if (this.loot) {
        this.loot.label.style.left = `${this.x}px`;
        this.loot.label.style.top = `${this.y - SIZE / 2 - 14}px`;
      }
    }

    setSprite(name, frame) {
      const sprite = spriteSets[name][frame % spriteSets[name].length];
      this.el.style.backgroundPosition = `${sprite[0] * SIZE}px ${sprite[1] * SIZE}px`;
    }

    say(text) {
      if (quiet()) return;
      const bubble = document.createElement("span");
      bubble.className = "oneko-bubble";
      bubble.textContent = text;
      // Above the cat, or below it when there is no room up top.
      const above = this.y - SIZE - 14;
      bubble.style.left = `${Math.min(window.innerWidth - 60, Math.max(60, this.x))}px`;
      bubble.style.top = `${above < 4 ? this.y + SIZE / 2 + 6 : above}px`;
      document.body.appendChild(bubble);
      setTimeout(() => bubble.remove(), 2300);
    }

    petted() {
      invite();
      puff("♡", "oneko-heart", this.x, this.y - SIZE / 2);
      if (parked) {
        wake();
        this.say("!");
        return;
      }
      window.dispatchEvent(new CustomEvent("oneko:meow"));
      const milestone = countPet();
      if (this.loot) {
        this.giveBack();
        this.say("fine... (=｀ェ´=)");
      } else if (this.plan && ["perch", "box"].includes(this.plan.kind)) {
        this.drop();
        this.say("purr ♡");
        this.wander();
      } else {
        this.say(milestone || (lateNight ? "go to sleep (－_－) zzZ" : random(MEOWS)));
      }
      this.clicks += 1;
      clearTimeout(this.clickTimer);
      this.clickTimer = setTimeout(() => (this.clicks = 0), 2000);
      if (this.clicks >= 3 && window.activateTerminal) {
        this.clicks = 0;
        window.activateTerminal();
      }
    }

    // Pick it up with a mouse or finger. A drag is not a pet.
    listenForDrag() {
      let held = null;
      let dragged = false;
      this.el.style.cursor = "grab";
      this.el.addEventListener("pointerdown", (event) => {
        if (event.button !== 0) return;
        event.stopPropagation();
        invite();
        held = { id: event.pointerId, x: event.clientX, y: event.clientY, dx: this.x - event.clientX, dy: this.y - event.clientY };
        dragged = false;
        this.held = true;
        this.drop();
        this.giveBack();
        this.el.setPointerCapture(event.pointerId);
        this.el.style.cursor = "grabbing";
      });
      this.el.addEventListener("pointermove", (event) => {
        if (!held || held.id !== event.pointerId) return;
        event.stopPropagation();
        dragged ||= Math.hypot(event.clientX - held.x, event.clientY - held.y) > 4;
        if (!dragged) return;
        parked = false;
        home?.classList.add("oneko-away");
        this.x = Math.max(16, Math.min(window.innerWidth - 16, event.clientX + held.dx));
        this.y = Math.max(16, Math.min(window.innerHeight - 16, event.clientY + held.dy));
        this.place();
        this.setSprite("alert", 0);
      });
      const release = (event) => {
        if (!held || held.id !== event.pointerId) return;
        this.suppressClick = dragged || event.type !== "pointerup";
        held = null;
        this.held = false;
        this.el.style.cursor = "grab";
        if (this.el.hasPointerCapture(event.pointerId)) this.el.releasePointerCapture(event.pointerId);
        pointer = null;
        // On articles it stays where you put it until the next page.
        invitedUntil = 0;
        this.readerSpot = dragged ? { x: this.x, y: this.y } : null;
      };
      this.el.addEventListener("pointerup", release);
      this.el.addEventListener("pointercancel", release);
      this.el.addEventListener("lostpointercapture", release);
    }

    // Rubbing back and forth over the cat with the mouse makes it purr.
    listenForRubs() {
      let lastX = null;
      let way = 0;
      let flips = 0;
      let flippedAt = 0;
      this.el.addEventListener("pointermove", (event) => {
        if (event.pointerType !== "mouse" || parked || this.held) {
          return;
        }
        const dx = event.clientX - (lastX ?? event.clientX);
        lastX = event.clientX;
        if (Math.abs(dx) < 2) {
          return;
        }
        if (Date.now() - flippedAt > 600) {
          flips = 0;
        }
        if (Math.sign(dx) !== way) {
          way = Math.sign(dx);
          flips += 1;
          flippedAt = Date.now();
        }
        if (flips >= 4) {
          flips = 0;
          this.purr();
        }
      });
      this.el.addEventListener("pointerleave", () => {
        lastX = null;
      });
    }

    purr() {
      const purring = Date.now() < this.purrUntil;
      this.purrUntil = Date.now() + 1800;
      if (purring) {
        return;
      }
      this.drop();
      this.say(countPet() || "purrrr ♡");
      window.dispatchEvent(new CustomEvent("oneko:purr"));
    }

    // Walk one step toward (tx, ty). Returns true once there.
    step(tx, ty, closeEnough, speed = SPEED) {
      const dx = this.x - tx;
      const dy = this.y - ty;
      const distance = Math.hypot(dx, dy);
      if (distance < closeEnough) {
        return true;
      }
      if (this.idleTime > 1) {
        this.setSprite("alert", 0);
        this.idleTime = Math.min(this.idleTime, 7) - 1;
        return false;
      }
      let direction = dy / distance > 0.5 ? "N" : "";
      direction += dy / distance < -0.5 ? "S" : "";
      direction += dx / distance > 0.5 ? "W" : "";
      direction += dx / distance < -0.5 ? "E" : "";
      this.setSprite(direction || "S", this.frameCount);
      const move = Math.min(speed, distance);
      this.x -= (dx / distance) * move;
      this.y -= (dy / distance) * move;
      this.place();
      this.trail(Math.atan2(-dy, -dx));
      return false;
    }

    trail(angle) {
      const degrees = (angle * 180) / Math.PI;
      if (Date.now() < nyanUntil) {
        mark("oneko-rainbow", this.x - 7, this.y - 9, degrees, 1200);
      } else if (this.frameCount % 3 === 0) {
        const side = this.frameCount % 6 === 0 ? 4 : -4;
        mark("oneko-print", this.x - 5 + side, this.y + 6, degrees + 90);
      }
    }

    resetIdleAnimation() {
      this.idleAnimation = null;
      this.idleAnimationFrame = 0;
    }

    idle() {
      this.idleTime += 1;
      const quiet = Date.now() - lastPointerAt > 4000;
      if (quiet && this.idleTime > 10 && !this.idleAnimation && !this.plan && Math.random() < 1 / 40) {
        this.mischief();
      }

      switch (this.idleAnimation) {
        case "sleeping":
          if (this.idleAnimationFrame < 8) {
            this.setSprite("tired", 0);
            break;
          }
          this.setSprite("sleeping", Math.floor(this.idleAnimationFrame / 4));
          if (this.idleAnimationFrame % 15 === 0) {
            puff("z", "oneko-z", this.x + 8, this.y - 10, "6px");
          }
          if (this.idleAnimationFrame > 192) {
            this.resetIdleAnimation();
          }
          break;
        case "scratchSelf":
          this.setSprite("scratchSelf", this.idleAnimationFrame);
          if (this.idleAnimationFrame > 9) {
            this.resetIdleAnimation();
          }
          break;
        default:
          this.setSprite("idle", 0);
          return;
      }
      this.idleAnimationFrame += 1;
    }

    mischief() {
      if (lateNight && Math.random() < 0.6) {
        this.idleAnimation = "sleeping";
        return;
      }
      const options = [
        [0.17, () => this.bite()],
        [0.07, () => this.knock()],
        [0.09, () => this.push()],
        [0.11, () => this.steal()],
        [0.07, () => this.perch()],
        [0.09, () => this.scratch()],
        [0.09, () => this.peek()],
        [0.11, () => this.nap()],
        [0.07, () => this.hunt()],
        [0.07, () => this.box()],
        [0.06, () => (this.idleAnimation = "scratchSelf")],
      ];
      let roll = Math.random();
      for (const [weight, act] of options) {
        roll -= weight;
        if (roll <= 0) {
          if (act() === false) {
            this.idleAnimation = "scratchSelf";
          }
          return;
        }
      }
    }

    start(plan) {
      this.drop();
      this.plan = { frame: 0, arrived: false, ...plan };
      this.resetIdleAnimation();
      return true;
    }

    // Forget the plan, tidying up anything it left behind.
    drop() {
      const plan = this.plan;
      this.plan = null;
      if (plan && plan.cleanup) {
        plan.cleanup();
      }
    }

    // Plans say where to stand (where) and what to do once there (act).

    onElement(kind, selector, test, act) {
      const targets = visible(selector, test);
      if (targets.length === 0) {
        return false;
      }
      const el = random(targets);
      const side = random(["top", "left", "right"]);
      const offset = between(0.15, 0.85);
      return this.start({
        kind,
        el,
        frames: 8,
        where: () => {
          const rect = el.getBoundingClientRect();
          if (side === "top") {
            const ex = rect.left + rect.width * offset;
            return { rect, ex, ey: rect.top, sx: ex, sy: rect.top - SIZE / 2 + 4 };
          }
          const ey = rect.top + rect.height * Math.min(offset, 0.5);
          const ex = side === "left" ? rect.left : rect.right;
          const sx = side === "left" ? ex - SIZE / 2 + 4 : ex + SIZE / 2 - 4;
          return { rect, ex, ey, sx, sy: ey };
        },
        act: (frame, where) => {
          this.setSprite(frame % 2 ? "scratchSelf" : "idle", frame);
          if (frame === 4) {
            act(el, where, side);
          }
        },
      });
    }

    bite() {
      if (reading()) return false;
      return this.onElement(
        "bite",
        SOLID,
        (el, rect) => rect.width > 40 && rect.height > 14 && (el.onekoBites || []).length < MAX_BITES,
        (el, where) => {
          chomp(el, where.ex - where.rect.left, where.ey - where.rect.top);
          crumbs(where.ex, where.ey);
        },
      );
    }

    knock() {
      if (reading()) return false;
      return this.onElement(
        "knock",
        SOLID,
        (el, rect) => rect.width > 40 && !el.style.rotate,
        (el, where, side) => tilt(el, (side === "left" ? 1 : -1) * between(3, 7)),
      );
    }

    push() {
      if (reading()) return false;
      const targets = visible(
        SOLID,
        (el, rect) => rect.width > 40 && rect.width < window.innerWidth * 0.8 && !el.onekoShoved,
      );
      if (targets.length === 0) {
        return false;
      }
      const el = random(targets);
      const rect = el.getBoundingClientRect();
      // Shove toward the closer edge, standing on the other side.
      const direction = rect.left + rect.width / 2 > window.innerWidth / 2 ? 1 : -1;
      return this.start({
        kind: "push",
        el,
        frames: 14,
        where: () => {
          const now = el.getBoundingClientRect();
          const sx = direction === 1 ? now.left - SIZE / 2 + 6 : now.right + SIZE / 2 - 6;
          return { sx, sy: now.top + Math.min(now.height / 2, 40) };
        },
        act: (frame) => {
          this.setSprite(direction === 1 ? "E" : "W", frame);
          if (frame === 3) {
            shove(el, direction);
          }
          if (frame > 3) {
            this.x = Math.max(16, Math.min(window.innerWidth - 16, this.x + direction * 4));
            this.place();
          }
        },
      });
    }

    steal() {
      if (reading()) return false;
      if (this.loot) {
        return false;
      }
      const word = pickWord();
      if (!word) {
        return false;
      }
      return this.start({
        kind: "steal",
        el: word,
        frames: 4,
        where: () => {
          const rect = word.getBoundingClientRect();
          return { sx: rect.left + rect.width / 2, sy: rect.top - SIZE / 2 + 6 };
        },
        act: (frame) => {
          this.setSprite("scratchSelf", frame);
          if (frame === 3) {
            const label = document.createElement("span");
            label.className = "oneko-loot";
            label.textContent = word.textContent;
            document.body.appendChild(label);
            word.style.visibility = "hidden";
            this.loot = { word, label, timer: setTimeout(() => this.giveBack(), HEAL_AFTER) };
            this.place();
          }
        },
        then: () => this.wander(),
      });
    }

    giveBack() {
      if (!this.loot) {
        return;
      }
      const { word, label, timer } = this.loot;
      this.loot = null;
      clearTimeout(timer);
      const rect = word.getBoundingClientRect();
      label.style.transition = "left 500ms ease, top 500ms ease";
      label.style.left = `${rect.left + rect.width / 2}px`;
      label.style.top = `${rect.top}px`;
      setTimeout(() => {
        label.remove();
        word.style.visibility = "";
      }, 500);
    }

    perch() {
      const targets = visible(PERCHES);
      if (targets.length === 0) {
        return false;
      }
      const el = random(targets);
      return this.start({
        kind: "perch",
        el,
        frames: 250,
        // A sitting cat ignores the cursor until you pet it.
        stubborn: true,
        where: () => {
          const rect = el.getBoundingClientRect();
          return { sx: rect.left + rect.width / 2, sy: rect.top + rect.height / 2 };
        },
        act: (frame) => {
          this.setSprite(frame % 40 < 3 ? "alert" : "idle", 0);
        },
      });
    }

    scratch() {
      const edges = [
        ["W", { sx: 16, sy: this.y }],
        ["E", { sx: window.innerWidth - 16, sy: this.y }],
        ["N", { sx: this.x, sy: 16 }],
        ["S", { sx: this.x, sy: window.innerHeight - 16 }],
      ];
      const distances = [this.x, window.innerWidth - this.x, this.y, window.innerHeight - this.y];
      const [wall, spot] = edges[distances.indexOf(Math.min(...distances))];
      return this.start({
        kind: "scratch",
        frames: 16,
        where: () => spot,
        act: (frame) => {
          this.setSprite(`scratchWall${wall}`, frame);
          if (frame === 8) {
            const cx = { W: 2, E: window.innerWidth - 24 }[wall] ?? this.x - 11;
            const cy = { N: 2, S: window.innerHeight - 28 }[wall] ?? this.y - 13;
            mark("oneko-claws", cx, cy, 0, 12000);
          }
        },
      });
    }

    peek() {
      // Only the top edge needs to be on screen.
      const targets = visible(
        PICTURES,
        (el, rect) =>
          rect.width > 60 &&
          rect.height > 50 &&
          rect.top > 60 &&
          rect.top < window.innerHeight - 40 &&
          rect.left > 8 &&
          rect.right < window.innerWidth - 8,
        false,
      );
      if (targets.length === 0) {
        return false;
      }
      const el = random(targets);
      const offset = between(0.2, 0.8);
      return this.start({
        kind: "peek",
        el,
        frames: 50,
        where: () => {
          const rect = el.getBoundingClientRect();
          return { sx: rect.left + rect.width * offset, sy: rect.top + 2 };
        },
        act: (frame) => {
          // Only the head shows, as if hiding behind the picture.
          this.el.style.clipPath = "inset(0 0 45% 0)";
          this.setSprite(frame % 25 < 3 ? "alert" : "idle", 0);
        },
        cleanup: () => {
          this.el.style.clipPath = "";
        },
      });
    }

    nap() {
      const middle = window.innerHeight / 2;
      const distance = (el) => Math.abs(el.getBoundingClientRect().top - middle);
      const paragraphs = visible(WORDY).sort((a, b) => distance(a) - distance(b));
      if (paragraphs.length === 0) {
        return false;
      }
      const el = paragraphs[0];
      return this.start({
        kind: "nap",
        el,
        frames: 150,
        where: () => {
          const rect = el.getBoundingClientRect();
          return window.innerWidth - rect.right > SIZE + 8
            ? { sx: rect.right + SIZE / 2 + 4, sy: rect.top + 10 }
            : { sx: rect.right - SIZE / 2, sy: rect.top - SIZE / 2 + 4 };
        },
        act: (frame) => {
          this.setSprite(frame < 8 ? "tired" : "sleeping", Math.floor(frame / 4));
          if (frame % 15 === 0) {
            puff("z", "oneko-z", this.x + 8, this.y - 10, "6px");
          }
        },
      });
    }

    // A butterfly flutters by and the cat tries to catch it.
    hunt() {
      if (butterfly) {
        return false;
      }
      const fly = (butterfly = new Butterfly());
      const until = Date.now() + 12000;
      return this.start({
        kind: "hunt",
        el: fly.el,
        frames: 8,
        speed: 13,
        where: () => (Date.now() > until ? { sx: this.x, sy: this.y } : { sx: fly.x, sy: fly.y + 14 }),
        act: (frame) => {
          this.setSprite("scratchWallN", frame);
          if (frame === 1) {
            const missed = Date.now() > until;
            fly.leave();
            this.say(missed ? "next time... (=ↀωↀ=)" : random(["!!", "so close (=ↀωↀ=)", "mrrrow!"]));
          }
        },
      });
    }

    // If it fits, it sits.
    box() {
      const bx = Math.max(40, Math.min(window.innerWidth - 40, this.x + between(-200, 200)));
      const by = window.innerHeight - between(40, 90);
      const el = document.createElement("div");
      el.className = "oneko-box";
      el.setAttribute("aria-hidden", "true");
      el.style.left = `${bx}px`;
      el.style.top = `${by}px`;
      document.body.appendChild(el);
      return this.start({
        kind: "box",
        el,
        frames: 160,
        stubborn: true,
        where: () => ({ sx: bx, sy: by + 5 }),
        act: (frame) => {
          if (frame === 2) {
            this.say("if i fits, i sits");
          }
          if (frame > 60 && frame < 140) {
            this.setSprite("sleeping", Math.floor(frame / 4));
          } else {
            this.setSprite(frame % 50 < 3 ? "alert" : "idle", 0);
          }
        },
        then: () => {
          this.y = by - SIZE / 2;
          this.place();
        },
        cleanup: () => {
          el.classList.add("oneko-box-gone");
          setTimeout(() => el.remove(), 400);
        },
      });
    }

    // Wiggle, then leap at the cursor.
    pounce() {
      return this.start({
        kind: "pounce",
        frames: 10,
        stubborn: true,
        where: () => ({ sx: this.x, sy: this.y }),
        act: (frame) => {
          this.setSprite("alert", 0);
          this.el.style.translate = `${frame % 2 ? 2 : -2}px 0`;
        },
        cleanup: () => {
          this.el.style.translate = "";
        },
        then: () =>
          this.start({
            kind: "leap",
            frames: 1,
            speed: 30,
            stubborn: true,
            where: () => (pointer ? { sx: pointer.x, sy: pointer.y } : { sx: this.x, sy: this.y }),
            act: () => {},
            then: () => puff("!", "oneko-z", this.x, this.y - SIZE / 2),
          }),
      });
    }

    // Paw at the end of the text you selected.
    swat(rect) {
      return this.start({
        kind: "swat",
        frames: 12,
        where: () => ({ sx: rect.right - 6, sy: rect.top - SIZE / 2 + 4 }),
        act: (frame) => this.setSprite("scratchWallS", frame),
      });
    }

    eat(treat) {
      return this.start({
        kind: "eat",
        frames: 14,
        stubborn: true,
        where: () => ({ sx: this.x, sy: this.y }),
        act: (frame) => {
          this.setSprite(frame % 4 < 2 ? "tired" : "idle", 0);
          if (frame % 4 === 1 && frame < 12) {
            puff("nom", "oneko-z", this.x + 6, this.y - 8, `${between(-8, 8)}px`);
          }
          if (frame === 6) {
            treat.el.style.clipPath = "inset(0 50% 0 0)";
          }
          if (frame === 12) {
            treat.el.remove();
            puff("♡", "oneko-heart", this.x, this.y - SIZE / 2);
            this.say("nom nom ♡");
            window.dispatchEvent(new CustomEvent("oneko:nom"));
          }
        },
        cleanup: () => treat.el.remove(),
      });
    }

    wander() {
      const spot = {
        sx: between(40, window.innerWidth - 40),
        sy: between(60, window.innerHeight - 40),
      };
      return this.start({ kind: "wander", frames: 1, where: () => spot, act: () => {} });
    }

    // Run after something that moves, like Sonic, for a while.
    chase(point, duration) {
      const until = Date.now() + duration;
      return this.start({
        kind: "chase",
        frames: 1,
        speed: 16,
        stubborn: true,
        where: () => {
          const spot = point();
          if (!spot || Date.now() > until) {
            return { sx: this.x, sy: this.y };
          }
          return { sx: spot.x, sy: spot.y };
        },
        act: () => {},
        then: () => {
          if (Date.now() < until && point()) {
            this.chase(point, until - Date.now());
          }
        },
      });
    }

    come() {
      const spot = pointer || { x: window.innerWidth / 2, y: window.innerHeight / 2 };
      this.giveBack();
      this.drop();
      this.say("!");
      this.idleTime = 0;
      return this.start({
        kind: "come",
        frames: 1,
        speed: 22,
        where: () => ({ sx: spot.x, sy: spot.y }),
        act: () => {},
        then: () => this.say(random(["mrrp?", "nya~"])),
      });
    }

    doPlan() {
      const plan = this.plan;
      if (plan.el && !plan.el.isConnected) {
        this.drop();
        return;
      }
      const where = plan.where();
      if (!plan.arrived) {
        const speed = Date.now() < nyanUntil ? 18 : plan.speed || SPEED;
        plan.arrived = this.step(where.sx, where.sy, Math.max(speed, 6), speed);
        if (!plan.arrived) {
          return;
        }
        this.x = where.sx;
        this.y = where.sy;
        this.place();
      }
      this.idleTime = 0;
      plan.frame += 1;
      plan.act(plan.frame, where);
      if (plan.frame >= plan.frames) {
        this.drop();
        if (plan.then) {
          plan.then();
        }
      }
    }

    // Stop what it is doing, unless it is sitting somewhere on purpose.
    distract() {
      if (this.plan && !this.plan.stubborn) {
        this.drop();
      }
    }

    frame() {
      this.frameCount += 1;
      this.el.hidden = Boolean(reading() && this.leader);
      if (this.el.hidden) return;
      if (this.held) return;
      if (quiet()) {
        this.drop();
        if (this.loot) this.giveBack();
        const spot = this.readerSpot || progressSpot();
        this.x = Math.max(16, Math.min(window.innerWidth - 16, spot.x));
        this.y = Math.max(16, Math.min(window.innerHeight - 16, spot.y));
        this.place();
        const max = document.documentElement.scrollHeight - window.innerHeight;
        const name = this.readerSpot || calm ? "idle" : window.scrollY >= max - 4 ? "sleeping" : Date.now() - readingScrollAt < 300 ? "E" : "idle";
        this.setSprite(name, name === "sleeping" ? Math.floor(this.frameCount / 4) : this.frameCount);
        if (yarn) yarn.el.hidden = true;
        return;
      }

      // Napping in the logo until someone wakes it up.
      if (parked) {
        const spot = homeSpot();
        this.x = spot.x;
        this.y = spot.y;
        this.place();
        this.setSprite(this.frameCount % 60 < 50 ? "idle" : "scratchSelf", this.frameCount);
        return;
      }

      if (Date.now() < this.purrUntil) {
        this.setSprite("tired", 0);
        if (this.frameCount % 3 === 0) {
          puff("♡", "oneko-heart", this.x + between(-8, 8), this.y - SIZE / 2, `${between(-14, 14)}px`);
        }
        return;
      }

      if (this.plan) {
        this.doPlan();
        return;
      }

      if (Date.now() < nyanUntil) {
        this.wander();
        return;
      }

      const treat = treats.find((t) => t.landed);
      if (treat) {
        if (this.step(treat.x, treat.y - 8, 12, 16)) {
          treats.splice(treats.indexOf(treat), 1);
          this.eat(treat);
        }
        return;
      }

      if (yarn && yarn.interesting()) {
        if (this.step(yarn.x, yarn.y, 18, 14)) {
          yarn.bat(this);
          this.setSprite("scratchSelf", this.frameCount);
        }
        return;
      }

      if (this.leader) {
        if (this.step(this.leader.x - 36, this.leader.y + 6, 30)) {
          this.idle();
        }
        return;
      }

      if (pointer) {
        // After sitting a while, it sometimes pounces instead of walking over.
        const far = Math.hypot(this.x - pointer.x, this.y - pointer.y) > 160;
        if (!touch && far && this.idleTime > 20 && Math.random() < 0.4) {
          this.pounce();
          return;
        }
        if (!this.step(pointer.x, pointer.y, touch ? 12 : 48)) {
          this.resetIdleAnimation();
          return;
        }
        // Fingers lift, so a tap is a place to run to, not something to keep chasing.
        if (touch) {
          pointer = null;
        }
      }

      this.idle();
    }
  }

  // A ball of yarn to throw around.

  class Yarn {
    constructor() {
      this.x = 28;
      this.y = window.innerHeight - 28;
      this.vx = 0;
      this.vy = 0;
      this.bats = 0;
      this.thrownAt = 0;
      this.drag = null;
      this.rolling = false;
      this.el = document.createElement("div");
      this.el.className = "oneko-yarn";
      this.el.setAttribute("aria-hidden", "true");
      document.body.appendChild(this.el);
      this.place();

      this.el.addEventListener("pointerdown", (event) => {
        event.preventDefault();
        this.el.setPointerCapture(event.pointerId);
        this.drag = { x: event.clientX, y: event.clientY, t: performance.now(), vx: 0, vy: 0 };
        this.vx = 0;
        this.vy = 0;
      });
      this.el.addEventListener("pointermove", (event) => {
        if (!this.drag) {
          return;
        }
        const t = performance.now();
        const frames = Math.max(1, t - this.drag.t) / 16;
        this.drag.vx = (event.clientX - this.drag.x) / frames;
        this.drag.vy = (event.clientY - this.drag.y) / frames;
        this.drag.x = event.clientX;
        this.drag.y = event.clientY;
        this.drag.t = t;
        this.x = event.clientX;
        this.y = event.clientY;
        this.place();
      });
      const release = () => {
        if (!this.drag) {
          return;
        }
        this.vx = Math.max(-30, Math.min(30, this.drag.vx));
        this.vy = Math.max(-30, Math.min(30, this.drag.vy));
        this.drag = null;
        this.thrownAt = Date.now();
        this.bats = 0;
        this.roll();
      };
      this.el.addEventListener("pointerup", release);
      this.el.addEventListener("pointercancel", release);
      window.addEventListener("resize", () => {
        this.keepInside(false);
        this.place();
      });
    }

    roll() {
      if (!this.rolling) {
        this.rolling = true;
        requestAnimationFrame(() => this.tick());
      }
    }

    tick() {
      this.x += this.vx;
      this.y += this.vy;
      this.vx *= 0.96;
      this.vy *= 0.96;
      this.keepInside(true);
      this.place();
      if (Math.hypot(this.vx, this.vy) > 0.2) {
        requestAnimationFrame(() => this.tick());
      } else {
        this.rolling = false;
      }
    }

    keepInside(bounce) {
      const r = 12;
      const maxX = window.innerWidth - r;
      const maxY = window.innerHeight - r;
      if (this.x < r || this.x > maxX) {
        this.x = Math.max(r, Math.min(maxX, this.x));
        this.vx = bounce ? -this.vx * 0.7 : 0;
      }
      if (this.y < r || this.y > maxY) {
        this.y = Math.max(r, Math.min(maxY, this.y));
        this.vy = bounce ? -this.vy * 0.7 : 0;
      }
    }

    place() {
      this.el.style.left = `${this.x}px`;
      this.el.style.top = `${this.y}px`;
      this.el.style.rotate = `${(this.x + this.y) * 2}deg`;
    }

    throwFrom(px, py) {
      this.x = px;
      this.y = py;
      const angle = between(0, Math.PI * 2);
      this.vx = Math.cos(angle) * 12;
      this.vy = Math.sin(angle) * 12;
      this.thrownAt = Date.now();
      this.bats = 0;
      this.roll();
    }

    // Cats care for a few seconds after a throw, and bat it around a few times.
    interesting() {
      return !this.drag && Date.now() - this.thrownAt < 6000 && this.bats < 4;
    }

    bat(cat) {
      if (Math.hypot(this.vx, this.vy) > 3) {
        return;
      }
      this.bats += 1;
      const angle = Math.atan2(this.y - cat.y, this.x - cat.x) + between(-0.8, 0.8);
      const power = between(6, 12);
      this.vx = Math.cos(angle) * power;
      this.vy = Math.sin(angle) * power;
      this.thrownAt = Date.now();
      this.roll();
    }
  }

  // A butterfly that flutters around, dodges the cat and flies off after a while.

  class Butterfly {
    constructor() {
      this.x = Math.random() < 0.5 ? -10 : window.innerWidth + 10;
      this.y = between(80, window.innerHeight * 0.6);
      this.t = 0;
      this.dodgedAt = 0;
      this.leaving = false;
      this.aim();
      this.el = document.createElement("div");
      this.el.className = "oneko-butterfly";
      this.el.setAttribute("aria-hidden", "true");
      document.body.appendChild(this.el);
      this.timer = setTimeout(() => this.leave(), 15000);
      requestAnimationFrame(() => this.tick());
    }

    aim(x = between(60, window.innerWidth - 60), y = between(80, window.innerHeight - 80)) {
      this.tx = Math.max(30, Math.min(window.innerWidth - 30, x));
      this.ty = Math.max(50, Math.min(window.innerHeight - 30, y));
    }

    leave() {
      clearTimeout(this.timer);
      this.leaving = true;
      this.tx = this.x + between(-200, 200);
      this.ty = -80;
    }

    tick() {
      this.t += 1;
      const dx = this.tx - this.x;
      const dy = this.ty - this.y;
      const distance = Math.hypot(dx, dy) || 1;
      if (distance < 10 && !this.leaving) {
        this.aim();
      }
      const speed = this.leaving ? 3 : 1.3;
      this.x += (dx / distance) * speed;
      this.y += (dy / distance) * speed + Math.sin(this.t / 6) * 1.2;
      const close = cats.some((cat) => Math.hypot(cat.x - this.x, cat.y - this.y) < 50);
      if (close && !this.leaving && Date.now() - this.dodgedAt > 1500) {
        // A little hop up and out of reach.
        this.dodgedAt = Date.now();
        this.aim(this.x + between(-150, 150), this.y - between(60, 120));
      }
      this.el.style.left = `${this.x}px`;
      this.el.style.top = `${this.y}px`;
      if (this.leaving && this.y < -30) {
        this.el.remove();
        butterfly = null;
        return;
      }
      requestAnimationFrame(() => this.tick());
    }
  }

  // A fish falls from the sky and the closest cat runs to eat it.
  function dropTreat(x = pointer ? pointer.x : between(80, window.innerWidth - 80)) {
    invite();
    const tx = Math.max(20, Math.min(window.innerWidth - 20, x));
    const ty = between(window.innerHeight * 0.45, window.innerHeight - 60);
    const el = document.createElement("div");
    el.className = "oneko-fish";
    el.setAttribute("aria-hidden", "true");
    el.style.left = `${tx}px`;
    el.style.top = `${ty}px`;
    el.style.setProperty("--fall", `${ty + 20}px`);
    document.body.appendChild(el);
    const treat = { x: tx, y: ty, el, landed: false };
    treats.push(treat);
    setTimeout(() => (treat.landed = true), 700);
    if (parked) {
      wake();
    }
  }

  // Select some text and the cat may come paw at it.
  function listenForSelections() {
    let timer = null;
    document.addEventListener("selectionchange", () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        const selection = document.getSelection();
        const cat = cats[0];
        if (reading() || parked || !selection || selection.isCollapsed || !selection.toString().trim()) {
          return;
        }
        if ((cat.plan && cat.plan.stubborn) || Math.random() < 0.5) {
          return;
        }
        const rects = selection.getRangeAt(0).getClientRects();
        const rect = rects[rects.length - 1];
        if (rect && onScreen(rect, 0)) {
          cat.swat(rect);
        }
      }, 700);
    });
  }

  // Say hi to people who come back, after a while away or after switching tabs.
  function greet() {
    const seen = memory.get("seen", 0);
    memory.set("seen", Date.now());
    if (!reading() && seen && Date.now() - seen > 6 * 60 * 60 * 1000 && !lateNight) {
      setTimeout(() => cats[0].say("welcome back ♡"), 2000);
    }
    let leftAt = 0;
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        leftAt = Date.now();
      } else if (!reading() && leftAt && Date.now() - leftAt > 10000 && !parked) {
        cats.forEach((cat) => cat.say("you're back! ♡"));
      }
    });
  }

  // Keyboard secrets.

  function listenForSecrets() {
    let typed = "";
    document.addEventListener("keydown", (event) => {
      const tag = event.target.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || event.target.isContentEditable) {
        return;
      }
      typed = (typed + event.key.toLowerCase()).slice(-12);
      if (typed.endsWith("pspsps")) {
        typed = "";
        pspsps();
      } else if (typed.endsWith("nyan")) {
        typed = "";
        startNyan();
      } else if (typed.endsWith("fish")) {
        typed = "";
        dropTreat();
      }
    });
  }

  function pspsps() {
    invite();
    if (parked) wake();
    cats.forEach((cat) => cat.come());
  }

  function startNyan() {
    invite();
    nyanUntil = Date.now() + 8000;
    cats.forEach((cat) => {
      cat.distract();
      cat.say("nyan~");
    });
  }

  function addFriend() {
    const first = cats[0];
    cats.push(new Cat(first.x + 40, first.y + 10, first));
  }

  function homeSpot() {
    const rect = home.getBoundingClientRect();
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  }

  // On phones the yarn would sit on top of the page, so it only shows while in play.
  const roomy = () => window.innerWidth >= 700;

  function addYarn() {
    if (!yarn) {
      yarn = new Yarn();
    }
  }

  function wake() {
    parked = false;
    home.classList.add("oneko-away");
    if (roomy()) {
      addYarn();
    }
  }

  function main() {
    // A still logo is enough when motion is turned off.
    if (home && calm) {
      return;
    }
    addStyles();
    if (memory.get("pets", 0) >= 100) {
      hat = "crown";
    }
    const start = home ? homeSpot() : reading() ? progressSpot() : touch ? { x: window.innerWidth - 40, y: window.innerHeight - 40 } : { x: 32, y: 32 };
    cats.push(new Cat(start.x, start.y));
    if (home) {
      home.classList.add("oneko-home");
    }

    if (calm) {
      const update = () => { if (quiet()) cats.forEach((cat) => cat.frame()); };
      window.addEventListener("scroll", update, { passive: true });
      window.addEventListener("resize", update);
      return;
    }

    if (catDay) {
      addFriend();
    }

    document.addEventListener("mousemove", (event) => {
      if (touch || quiet()) {
        return;
      }
      pointer = { x: event.clientX, y: event.clientY };
      lastPointerAt = Date.now();
      // Mouse moves happen all the time, so only quick jobs get interrupted.
      cats.forEach((cat) => {
        if (cat.plan && ["nap", "peek", "wander"].includes(cat.plan.kind)) {
          cat.distract();
        }
      });
    });
    document.addEventListener("pointerdown", (event) => {
      if (quiet() || event.pointerType === "mouse" || event.target.closest(".oneko-cat, .oneko-yarn")) {
        return;
      }
      pointer = { x: event.clientX, y: event.clientY };
      lastPointerAt = Date.now();
      cats.forEach((cat) => cat.distract());
    });

    if (!parked && roomy()) {
      addYarn();
    }
    listenForSecrets();
    listenForSelections();
    greet();
    setInterval(() => {
      cats.forEach((cat) => cat.frame());
      if (yarn) {
        yarn.el.hidden = quiet() || !roomy() && !yarn.interesting() && !yarn.rolling;
      }
    }, TICK);

    if (lateNight && !reading()) {
      setTimeout(() => cats[0].say("*yawn*"), 3000);
    }
  }

  function setHat(name) {
    hat = name || null;
    cats.forEach((cat) => cat.wearHat());
  }

  const first = () => cats[0];
  window.oneko = {
    pet: () => first().petted(),
    hat: setHat,
    cats: () => cats.map((cat) => ({ x: cat.x, y: cat.y })),
    chase: (point, duration) => cats.forEach((cat) => cat.chase(point, duration)),
    play: () => {
      addYarn();
      if (!yarn.interesting()) {
        yarn.throwFrom(first().x, first().y);
      }
    },
    bite: () => first().bite(),
    knock: () => first().knock(),
    push: () => first().push(),
    steal: () => first().steal(),
    perch: () => first().perch(),
    scratch: () => first().scratch(),
    peek: () => first().peek(),
    nap: () => first().nap(),
    hunt: () => first().hunt(),
    box: () => first().box(),
    pounce: () => first().pounce(),
    treat: dropTreat,
    pets: () => memory.get("pets", 0),
    pspsps,
    nyan: startNyan,
    friend: addFriend,
  };

  window.addEventListener("site:navigate", () => {
    home = document.querySelector("[data-oneko-home]");
    parked = Boolean(home);
    pointer = null;
    invitedUntil = 0;
    cats.forEach((cat) => {
      cat.drop();
      cat.giveBack();
      cat.readerSpot = null;
      cat.idleTime = 0;
      if (quiet()) cat.frame();
    });
    if (home) home.classList.add("oneko-home");
  });
  main();
})();
