// A cat that chases the cursor (or your finger) and bites the page when bored.
// Based on oneko.js by adryd325 (MIT).
(function oneko() {
  const SIZE = 32;
  const SPEED = 10;
  const TICK = 100;
  const HEAL_AFTER = 30000;
  const MAX_BITES = 3;
  // Solid things, so the bite shows: pictures, cards, buttons, code, the logo.
  const BITE_TARGETS =
    "img, pre, figure, .app-card, .app-screenshot, .button, .terminal, .logo, .header-link, .post-title";

  const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const touch = !window.matchMedia("(pointer: fine)").matches;

  const spriteSets = {
    idle: [[-3, -3]],
    alert: [[-7, -3]],
    scratch: [
      [-5, 0],
      [-6, 0],
      [-7, 0],
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

  const nekoEl = document.createElement("div");
  let x = touch ? window.innerWidth - 40 : 32;
  let y = touch ? window.innerHeight - 40 : 32;
  let pointer = null;
  let lastPointerAt = 0;
  let frameCount = 0;
  let idleTime = 0;
  let idleAnimation = null;
  let idleAnimationFrame = 0;
  // What the cat is up to when it is not chasing you: { kind, el, side, offset, frame }.
  let plan = null;
  let clickCount = 0;
  let clickTimer = null;

  function addStyles() {
    const style = document.createElement("style");
    style.textContent = `
      .oneko-bitten { animation: oneko-shake 300ms ease; }
      @keyframes oneko-shake {
        25% { translate: -2px 0; }
        75% { translate: 2px 0; }
      }
      .oneko-bit {
        position: fixed;
        z-index: 2147483646;
        pointer-events: none;
        font: 700 14px/1 monospace;
        animation: oneko-fall 700ms ease-in forwards;
      }
      .oneko-heart { color: #f462c6; animation-name: oneko-float; }
      @keyframes oneko-fall {
        to { translate: var(--dx) 28px; opacity: 0; }
      }
      @keyframes oneko-float {
        to { translate: 0 -28px; opacity: 0; }
      }
    `;
    document.head.appendChild(style);
  }

  function create() {
    nekoEl.setAttribute("aria-hidden", "true");
    Object.assign(nekoEl.style, {
      position: "fixed",
      zIndex: "2147483647",
      width: `${SIZE}px`,
      height: `${SIZE}px`,
      backgroundImage: "url('/oneko.gif')",
      imageRendering: "pixelated",
      touchAction: "manipulation",
    });
    place();
    setSprite("idle", 0);
    document.body.appendChild(nekoEl);
    addStyles();

    nekoEl.addEventListener("click", (event) => {
      event.stopPropagation();
      puff("♡", "oneko-heart");
      clickCount += 1;
      clearTimeout(clickTimer);
      clickTimer = setTimeout(() => (clickCount = 0), 2000);
      if (clickCount >= 3 && window.activateTerminal) {
        clickCount = 0;
        window.activateTerminal();
      }
    });

    if (calm) {
      return;
    }

    document.addEventListener("mousemove", (event) => {
      if (!touch) {
        follow(event.clientX, event.clientY);
      }
    });
    document.addEventListener("pointerdown", (event) => {
      if (event.pointerType !== "mouse" && event.target !== nekoEl) {
        follow(event.clientX, event.clientY);
      }
    });

    setInterval(frame, TICK);
  }

  function follow(px, py) {
    pointer = { x: px, y: py };
    lastPointerAt = Date.now();
    plan = null;
  }

  function place() {
    nekoEl.style.left = `${x - SIZE / 2}px`;
    nekoEl.style.top = `${y - SIZE / 2}px`;
  }

  function setSprite(name, frame) {
    const sprite = spriteSets[name][frame % spriteSets[name].length];
    nekoEl.style.backgroundPosition = `${sprite[0] * SIZE}px ${sprite[1] * SIZE}px`;
  }

  function directionTo(dx, dy, distance) {
    let direction = dy / distance > 0.5 ? "N" : "";
    direction += dy / distance < -0.5 ? "S" : "";
    direction += dx / distance > 0.5 ? "W" : "";
    direction += dx / distance < -0.5 ? "E" : "";
    return direction || "S";
  }

  // Walk one step toward (tx, ty). Returns true once there.
  function step(tx, ty, closeEnough) {
    const dx = x - tx;
    const dy = y - ty;
    const distance = Math.hypot(dx, dy);
    if (distance < closeEnough) {
      return true;
    }
    if (idleTime > 1) {
      setSprite("alert", 0);
      idleTime = Math.min(idleTime, 7) - 1;
      return false;
    }
    setSprite(directionTo(dx, dy, distance), frameCount);
    const move = Math.min(SPEED, distance);
    x -= (dx / distance) * move;
    y -= (dy / distance) * move;
    place();
    return false;
  }

  function resetIdleAnimation() {
    idleAnimation = null;
    idleAnimationFrame = 0;
  }

  function idle() {
    idleTime += 1;

    const quiet = Date.now() - lastPointerAt > 4000;
    if (quiet && idleTime > 10 && idleAnimation === null && plan === null && Math.random() < 1 / 40) {
      pickMischief();
    }

    switch (idleAnimation) {
      case "sleeping":
        if (idleAnimationFrame < 8) {
          setSprite("tired", 0);
          break;
        }
        setSprite("sleeping", Math.floor(idleAnimationFrame / 4));
        if (idleAnimationFrame > 192) {
          resetIdleAnimation();
        }
        break;
      case "scratch":
        setSprite("scratch", idleAnimationFrame);
        if (idleAnimationFrame > 9) {
          resetIdleAnimation();
        }
        break;
      default:
        setSprite("idle", 0);
        return;
    }
    idleAnimationFrame += 1;
  }

  function pickMischief() {
    const roll = Math.random();
    if (roll < 0.55) {
      bite();
    } else if (roll < 0.7) {
      knock();
    } else if (roll < 0.85) {
      idleAnimation = "sleeping";
    } else {
      idleAnimation = "scratch";
    }
  }

  function visibleTargets() {
    return [...document.querySelectorAll(BITE_TARGETS)].filter((el) => {
      const rect = el.getBoundingClientRect();
      return (
        rect.width > 40 &&
        rect.height > 14 &&
        rect.top > 24 &&
        rect.bottom < window.innerHeight - 8 &&
        rect.left > 8 &&
        rect.right < window.innerWidth - 8 &&
        (el.onekoBites || []).length < MAX_BITES
      );
    });
  }

  function choose(kind) {
    const targets = visibleTargets();
    if (targets.length === 0) {
      return false;
    }
    const el = targets[Math.floor(Math.random() * targets.length)];
    const sides = ["top", "left", "right"];
    plan = {
      kind,
      el,
      side: sides[Math.floor(Math.random() * sides.length)],
      offset: 0.15 + Math.random() * 0.7,
      frame: 0,
    };
    resetIdleAnimation();
    return true;
  }

  function bite() {
    return choose("bite");
  }

  function knock() {
    return choose("knock");
  }

  // The spot on the element's edge, and where the cat stands to reach it.
  function spot() {
    const rect = plan.el.getBoundingClientRect();
    let ex;
    let ey;
    if (plan.side === "top") {
      ex = rect.left + rect.width * plan.offset;
      ey = rect.top;
      return { rect, ex, ey, sx: ex, sy: ey - SIZE / 2 + 4 };
    }
    ey = rect.top + rect.height * Math.min(plan.offset, 0.5);
    ex = plan.side === "left" ? rect.left : rect.right;
    const sx = plan.side === "left" ? ex - SIZE / 2 + 4 : ex + SIZE / 2 - 4;
    return { rect, ex, ey, sx, sy: ey };
  }

  function doMischief() {
    if (!plan.el.isConnected) {
      plan = null;
      return;
    }
    const where = spot();
    if (plan.frame === 0 && !step(where.sx, where.sy, SPEED)) {
      return;
    }
    // Chomp chomp.
    idleTime = 0;
    plan.frame += 1;
    setSprite(plan.frame % 2 ? "scratch" : "idle", plan.frame);
    if (plan.frame === 4) {
      if (plan.kind === "bite") {
        chomp(plan.el, where.ex - where.rect.left, where.ey - where.rect.top);
        crumbs(where.ex, where.ey);
      } else {
        nudge(plan.el, plan.side);
      }
    }
    if (plan.frame > 7) {
      plan = null;
    }
  }

  function chomp(el, bx, by) {
    const radius = Math.max(7, Math.min(14, el.getBoundingClientRect().height / 3));
    const bites = (el.onekoBites = el.onekoBites || []);
    const mark = { bx, by, radius };
    bites.push(mark);
    paintBites(el);
    el.classList.remove("oneko-bitten");
    void el.offsetWidth;
    el.classList.add("oneko-bitten");
    setTimeout(() => {
      bites.splice(bites.indexOf(mark), 1);
      paintBites(el);
    }, HEAL_AFTER);
  }

  function paintBites(el) {
    // A cartoon bite: three overlapping circles cut out of the edge.
    const holes = el.onekoBites.flatMap(({ bx, by, radius }) =>
      [-0.8, 0, 0.8].map(
        (shift) =>
          `radial-gradient(circle ${radius}px at ${bx + shift * radius}px ${by + Math.abs(shift) * 2}px, transparent 98%, #000 100%)`,
      ),
    );
    const value = holes.join(", ");
    const composite = holes.map(() => "intersect").join(", ");
    el.style.maskImage = value;
    el.style.webkitMaskImage = value;
    el.style.maskComposite = composite;
    el.style.webkitMaskComposite = holes.map(() => "source-in").join(", ");
  }

  function nudge(el, side) {
    const tilt = (side === "left" ? 1 : -1) * (3 + Math.random() * 4);
    el.style.transition = "rotate 300ms cubic-bezier(.3,1.6,.6,1)";
    el.style.rotate = `${tilt}deg`;
    setTimeout(() => {
      el.style.rotate = "";
    }, HEAL_AFTER);
  }

  function crumbs(cx, cy) {
    for (let i = 0; i < 4; i += 1) {
      puff("·", "", cx, cy, `${(Math.random() - 0.5) * 30}px`);
    }
  }

  function puff(text, className, px = x, py = y - SIZE / 2, dx = "0px") {
    const bit = document.createElement("span");
    bit.className = `oneko-bit ${className}`.trim();
    bit.textContent = text;
    bit.style.left = `${px - 4}px`;
    bit.style.top = `${py - 8}px`;
    bit.style.setProperty("--dx", dx);
    document.body.appendChild(bit);
    setTimeout(() => bit.remove(), 800);
  }

  function frame() {
    frameCount += 1;

    if (plan) {
      doMischief();
      return;
    }

    // Fingers lift, so a tap is a place to run to, not something to keep chasing.
    if (pointer) {
      const arrived = step(pointer.x, pointer.y, touch ? 12 : 48);
      if (arrived) {
        if (touch) {
          pointer = null;
        }
        idle();
      } else {
        resetIdleAnimation();
      }
      return;
    }

    idle();
  }

  window.oneko = { bite, knock };
  create();
})();
