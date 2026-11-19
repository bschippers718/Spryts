const {
  DEFAULT_SETTINGS,
  STATS_KEY,
  DIAGNOSTIC_DELAY_MS,
  settingsArea,
  localArea,
  normalizeTerm,
  getFeedInfo,
  isActiveFeedPath,
  compileRules,
  getHideReason,
  mergeEntries,
  parseHandles,
  splitEntries,
  parseBriefMetric,
  buildBrief,
  briefMatchedTopics,
  briefSummaryInput,
  topicLabelMap,
  suggestMutePhrases,
  pickFollowingTab,
  addToStats,
  normalizeStats,
  isDarkColor
} = SiftCore;

const settingsStore = settingsArea();
let settings = { ...DEFAULT_SETTINGS };
let stats = normalizeStats(null);
let applyTimer;
let lastPath = location.pathname;
let followingAttempted = false;
let isScrolling = false;
let scrollIdleTimer;
let reviewEscapeHandler;
let briefEscapeHandler;
let diagnosticTimer;
let pendingDiagnostic = "";
let diagnosticDismissedPath = "";
let statsFlushTimer;
let pendingFilteredCount = 0;
const countedHiddenKeys = new Set();
const stackRegistry = new Map();
const briefPostRegistry = new Map();
const MAX_BRIEF_POSTS = 250;
const TOAST_DURATION_MS = 6000;
const STATS_FLUSH_MS = 400;

function normalizeHandle(href) {
  if (!href) return "";

  try {
    const path = new URL(href, location.origin).pathname;
    const firstPart = path.split("/").filter(Boolean)[0] || "";
    const reserved = new Set([
      "home",
      "explore",
      "notifications",
      "messages",
      "i",
      "search",
      "settings",
      "compose"
    ]);
    return reserved.has(firstPart.toLowerCase()) ? "" : firstPart.toLowerCase();
  } catch {
    return "";
  }
}

function isExternalLink(anchor) {
  const href = anchor?.getAttribute("href");
  if (!href) return false;

  try {
    const url = new URL(href, location.origin);
    const internalHosts = new Set([
      "x.com",
      "www.x.com",
      "twitter.com",
      "www.twitter.com"
    ]);
    return (
      ["http:", "https:"].includes(url.protocol) &&
      (!internalHosts.has(url.hostname) || url.hostname === "t.co")
    );
  } catch {
    return false;
  }
}

function canonicalUrl(href) {
  if (!href) return "";
  try {
    return new URL(href, location.origin).href;
  } catch {
    return "";
  }
}

function engagementValue(article, testId) {
  const element = article.querySelector(`[data-testid="${testId}"]`);
  const label =
    element?.getAttribute("aria-label") ||
    element?.textContent ||
    element?.querySelector("[aria-label]")?.getAttribute("aria-label") ||
    "";
  return parseBriefMetric(label);
}

function extractPost(article) {
  const userName = article.querySelector('[data-testid="User-Name"]');
  const profileLink = userName?.querySelector('a[href^="/"]');
  const textNodes = Array.from(
    article.querySelectorAll('[data-testid="tweetText"]')
  );
  const text = textNodes
    .map((node) => node.innerText?.trim() || "")
    .filter(Boolean)
    .join(" ");
  const card = article.querySelector('[data-testid="card.wrapper"]');
  const contentText = `${text} ${card?.innerText || ""}`.trim();
  const socialContext =
    article.querySelector('[data-testid="socialContext"]')?.innerText || "";
  const contentLinks = [
    ...textNodes.flatMap((node) => Array.from(node.querySelectorAll("a[href]"))),
    ...Array.from(card?.querySelectorAll("a[href]") || [])
  ];
  const hasExternalLink = contentLinks.some(isExternalLink);
  const externalUrls = [
    ...new Set(
      contentLinks
        .filter(isExternalLink)
        .map((anchor) => canonicalUrl(anchor.getAttribute("href")))
        .filter(Boolean)
    )
  ];
  const handle = normalizeHandle(profileLink?.getAttribute("href"));
  const normalizedText = normalizeTerm(contentText);
  const statusHref =
    article.querySelector('a[href*="/status/"]')?.getAttribute("href") || "";
  const time = article.querySelector("time");
  const hasPromotedLabel = Array.from(article.querySelectorAll("span")).some(
    (element) => element.textContent?.trim().toLowerCase() === "promoted"
  );

  return {
    key: statusHref || `${handle}:${normalizedText.slice(0, 160)}`,
    handle,
    text,
    normalizedText,
    url: canonicalUrl(statusHref),
    timestamp: time?.getAttribute("datetime") || "",
    externalUrls,
    engagement: {
      replies: engagementValue(article, "reply"),
      reposts: engagementValue(article, "retweet"),
      likes: engagementValue(article, "like"),
      views: engagementValue(article, "app-text-transition-container")
    },
    isPromoted: hasPromotedLabel,
    isRepost: /repost(ed)?/i.test(socialContext),
    isQuote: Boolean(article.querySelector('[data-testid="quoteTweet"]')),
    hasExternalLink
  };
}

function safeFeedUrl() {
  return getFeedInfo(settings.feedUrl).url;
}

function setText(element, value) {
  if (element && element.textContent !== value) element.textContent = value;
}

function makeButton(className, label, onClick) {
  const button = document.createElement("button");
  button.type = "button";
  if (className) button.className = className;
  setText(button, label);
  button.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    onClick(button, event);
  });
  return button;
}

function openOptions() {
  chrome.runtime.sendMessage({ type: "open-options" });
}

function withoutHandle(value, handle) {
  return splitEntries(value)
    .filter((entry) => entry.trim().toLowerCase().replace(/^@/, "") !== handle)
    .join("\n");
}

function withoutTerm(value, term) {
  const target = normalizeTerm(term);
  return splitEntries(value)
    .filter((entry) => normalizeTerm(entry) !== target)
    .join("\n");
}

/* ---------- Theme ---------- */

function syncTheme() {
  const background = getComputedStyle(document.body).backgroundColor;
  const dark = isDarkColor(background);
  document.documentElement.classList.toggle("sift-dark", dark);
  if (dark) {
    document.documentElement.style.setProperty("--sift-surface", background);
  } else {
    document.documentElement.style.removeProperty("--sift-surface");
  }
}

/* ---------- Toast ---------- */

let toastTimer;

function closeToast() {
  clearTimeout(toastTimer);
  toastTimer = undefined;
  document.querySelector(".sift-toast")?.remove();
}

function showToast({ message, actions = [], duration = TOAST_DURATION_MS }) {
  closeToast();
  const toast = document.createElement("div");
  toast.className = "sift-toast";
  toast.setAttribute("role", "status");
  toast.setAttribute("aria-live", "polite");

  const copy = document.createElement("span");
  copy.className = "sift-toast-message";
  setText(copy, message);
  toast.append(copy);

  const actionRow = document.createElement("div");
  actionRow.className = "sift-toast-actions";
  for (const action of actions) {
    const button = makeButton(
      `sift-toast-action${action.primary ? " is-primary" : ""}`,
      action.label,
      () => action.onClick(toast)
    );
    if (action.title) button.title = action.title;
    actionRow.append(button);
  }
  const dismiss = makeButton("sift-toast-dismiss", "×", closeToast);
  dismiss.setAttribute("aria-label", "Dismiss");
  actionRow.append(dismiss);
  toast.append(actionRow);

  let remaining = duration;
  let startedAt = Date.now();
  const start = () => {
    clearTimeout(toastTimer);
    startedAt = Date.now();
    toastTimer = setTimeout(closeToast, remaining);
  };
  const pause = () => {
    clearTimeout(toastTimer);
    remaining = Math.max(1500, remaining - (Date.now() - startedAt));
  };
  toast.addEventListener("mouseenter", pause);
  toast.addEventListener("focusin", pause);
  toast.addEventListener("mouseleave", start);
  toast.addEventListener("focusout", (event) => {
    if (!toast.contains(event.relatedTarget)) start();
  });
  toast.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeToast();
  });

  document.body.append(toast);
  start();
  return toast;
}

/* ---------- Account preferences (Show less / Show more) ---------- */

function writeSettings(values, callback) {
  settingsStore.area.set(values, () => {
    callback?.(chrome.runtime.lastError);
  });
}

function showMuteSuggestions(toast, post, previous) {
  const suggestions = suggestMutePhrases(post, settings);
  const message = toast.querySelector(".sift-toast-message");
  const actionRow = toast.querySelector(".sift-toast-actions");
  actionRow.querySelectorAll(".sift-toast-action").forEach((b) => b.remove());

  if (suggestions.length === 0) {
    setText(message, `No phrase suggestions for this post. @${post.handle} stays hidden.`);
    actionRow.prepend(
      makeButton("sift-toast-action", "Undo", () => restorePreference(previous, post.handle))
    );
    return;
  }

  setText(message, `Mute a phrase instead of @${post.handle}:`);
  const chips = document.createElement("div");
  chips.className = "sift-toast-chips";
  for (const phrase of suggestions) {
    chips.append(
      makeButton("sift-toast-chip", `“${phrase}”`, () => mutePhrase(phrase, post, previous))
    );
  }
  message.after(chips);
  actionRow.prepend(
    makeButton("sift-toast-action", "Keep account hidden", closeToast)
  );
}

function mutePhrase(phrase, post, previous) {
  settingsStore.area.get(
    { mutedKeywords: "", hiddenHandles: "", trustedHandles: "" },
    (stored) => {
      if (chrome.runtime.lastError) return;
      const beforeMute = stored.mutedKeywords;
      writeSettings(
        {
          hiddenHandles: previous.hiddenHandles,
          trustedHandles: previous.trustedHandles,
          mutedKeywords: mergeEntries(stored.mutedKeywords, phrase)
        },
        (error) => {
          if (error) return;
          showToast({
            message: `Muted “${phrase}” instead of hiding @${post.handle}.`,
            actions: [
              {
                label: "Undo",
                onClick: () => {
                  writeSettings({ mutedKeywords: beforeMute }, () =>
                    showToast({ message: `Unmuted “${phrase}”`, duration: 2500 })
                  );
                }
              }
            ]
          });
        }
      );
    }
  );
}

function restorePreference(previous, handle) {
  writeSettings(previous, (error) => {
    if (error) return;
    showToast({ message: `Restored @${handle}`, duration: 2500 });
  });
}

function updateAccountPreference(handle, preference, button, post) {
  if (!handle || button.disabled) return;
  button.disabled = true;
  setText(button, "…");

  settingsStore.area.get(
    { hiddenHandles: "", trustedHandles: "" },
    (stored) => {
      if (chrome.runtime.lastError) {
        button.disabled = false;
        setText(button, button.dataset.siftLabel);
        return;
      }

      const targetKey =
        preference === "more" ? "trustedHandles" : "hiddenHandles";
      const oppositeKey =
        preference === "more" ? "hiddenHandles" : "trustedHandles";
      const isActive = parseHandles(stored[targetKey]).has(handle);
      const previous = {
        hiddenHandles: stored.hiddenHandles,
        trustedHandles: stored.trustedHandles
      };
      const values = {
        [targetKey]: isActive
          ? withoutHandle(stored[targetKey], handle)
          : mergeEntries(stored[targetKey], `@${handle}`),
        [oppositeKey]: isActive
          ? stored[oppositeKey]
          : withoutHandle(stored[oppositeKey], handle)
      };

      writeSettings(values, (error) => {
        if (error) {
          button.disabled = false;
          setText(button, button.dataset.siftLabel);
          return;
        }
        if (isActive) return;

        if (preference === "less") {
          const undo = {
            label: "Undo",
            primary: true,
            onClick: () => restorePreference(previous, handle)
          };
          const actions = [undo];
          if (post?.text) {
            actions.push({
              label: "Mute a phrase instead",
              title: "Keep this account, hide a topic from the post instead",
              onClick: (toast) => showMuteSuggestions(toast, post, previous)
            });
          }
          showToast({
            message: `Hidden @${handle}. You won’t see this account again.`,
            actions
          });
        } else {
          showToast({
            message: `@${handle} added to Priority accounts.`,
            duration: 4000,
            actions: [
              {
                label: "Undo",
                onClick: () => restorePreference(previous, handle)
              }
            ]
          });
        }
      });
    }
  );
}

function nativePostActions(article) {
  const nativeAction = article.querySelector(
    '[data-testid="reply"], [data-testid="retweet"], [data-testid="like"], [data-testid="bookmark"]'
  );
  return nativeAction?.closest('[role="group"]') || null;
}

function createPreferenceButton(className, label, preference) {
  const button = makeButton(className, label, (element) => {
    const article = element.closest('article[data-testid="tweet"]');
    const post = article ? briefPostRegistry.get(article.dataset.siftPostKey) : null;
    updateAccountPreference(element.dataset.siftHandle, preference, element, post);
  });
  button.dataset.siftLabel = label;
  return button;
}

function syncPostPreferenceActions(article, post, shouldShow, rules, topicLabels) {
  let controls = article.querySelector(":scope .sift-post-preferences");
  if (!shouldShow || !post.handle) {
    controls?.remove();
    return;
  }

  const actionRow = nativePostActions(article);
  if (!actionRow) {
    controls?.remove();
    return;
  }

  if (!controls) {
    controls = document.createElement("div");
    controls.className = "sift-post-preferences";
    controls.setAttribute("aria-label", "Sift feed preferences");
    const label = document.createElement("span");
    label.className = "sift-preference-label";
    setText(label, "Sift");
    const tag = document.createElement("span");
    tag.className = "sift-topic-tag";
    tag.hidden = true;

    const lessButton = createPreferenceButton(
      "sift-preference-action sift-auto-flag",
      "Show less",
      "less"
    );
    const moreButton = createPreferenceButton(
      "sift-preference-action sift-show-more",
      "Show more",
      "more"
    );
    controls.append(label, tag, lessButton, moreButton);
    actionRow.append(controls);
  }

  const tag = controls.querySelector(".sift-topic-tag");
  const matched = rules ? briefMatchedTopics(post, rules) : [];
  const isPriority = Boolean(rules?.trustedHandles.has(post.handle));
  if (matched.length > 0) {
    const label = topicLabels?.get(matched[0]) || matched[0];
    tag.hidden = false;
    setText(tag, label);
    tag.title =
      matched.length > 1
        ? `Kept: matches your topics ${matched
            .map((topic) => `“${topicLabels?.get(topic) || topic}”`)
            .join(", ")}`
        : `Kept: matches your topic “${label}”`;
  } else if (isPriority) {
    tag.hidden = false;
    setText(tag, "Priority");
    tag.title = `Kept: @${post.handle} is one of your Priority accounts`;
  } else {
    tag.hidden = true;
    setText(tag, "");
    tag.removeAttribute("title");
  }

  const lessButton = controls.querySelector(".sift-auto-flag");
  const moreButton = controls.querySelector(".sift-show-more");
  const lessSelected = parseHandles(settings.hiddenHandles).has(post.handle);
  const moreSelected = parseHandles(settings.trustedHandles).has(post.handle);
  const syncButton = (button, selected) => {
    button.dataset.siftHandle = post.handle;
    button.disabled = false;
    button.classList.toggle("is-selected", selected);
    button.setAttribute("aria-pressed", String(selected));
    setText(button, selected ? `✓ ${button.dataset.siftLabel}` : button.dataset.siftLabel);
  };
  syncButton(lessButton, lessSelected);
  syncButton(moreButton, moreSelected);
  lessButton.title = `Show fewer posts like this by hiding @${post.handle}`;
  lessButton.setAttribute(
    "aria-label",
    `Show fewer posts like this; never show @${post.handle}`
  );
  moreButton.title = `Show more posts from @${post.handle}`;
  moreButton.setAttribute(
    "aria-label",
    `Show me more posts from @${post.handle}`
  );
}

/* ---------- Navigation shortcuts ---------- */

function ensureFeedShortcut() {
  const existing = document.querySelector(".sift-feed-shortcut");
  const existingSettings = document.querySelector(".sift-settings-shortcut");

  const primaryNav = document.querySelector(
    'nav[aria-label="Primary"], nav[role="navigation"]'
  );
  if (!primaryNav) return;

  if (!settings.enabled) {
    existing?.remove();
  } else if (!existing) {
    const link = document.createElement("a");
    link.className = "sift-feed-shortcut";
    link.href = safeFeedUrl() || "https://x.com/home";
    const icon = document.createElement("span");
    icon.className = "sift-feed-icon";
    icon.setAttribute("aria-hidden", "true");
    setText(icon, "✦");
    const label = document.createElement("span");
    label.className = "sift-feed-label";
    link.append(icon, label);
    primaryNav.append(link);
  }

  const shortcut = document.querySelector(".sift-feed-shortcut");
  if (shortcut) {
    const feedName = settings.profileName || "My Feed";
    shortcut.href = safeFeedUrl() || "https://x.com/home";
    shortcut.setAttribute("aria-label", `Open ${feedName}`);
    setText(shortcut.querySelector(".sift-feed-label"), feedName);
  }

  if (!existingSettings) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "sift-settings-shortcut";
    button.setAttribute("aria-label", "Open Sift settings");
    const icon = document.createElement("span");
    icon.className = "sift-settings-icon";
    icon.setAttribute("aria-hidden", "true");
    setText(icon, "⚙");
    const label = document.createElement("span");
    label.className = "sift-settings-label";
    setText(label, "Feed settings");
    button.append(icon, label);
    button.addEventListener("click", openOptions);
    primaryNav.append(button);
  }
}

/* ---------- Brief data + on-device AI summaries ---------- */

const SUMMARIZER_OPTIONS = Object.freeze({
  type: "tldr",
  format: "plain-text",
  length: "short",
  outputLanguage: "en",
  sharedContext:
    "These are short social media posts from different accounts about the same story. Write one or two neutral, factual sentences stating what happened. Do not mention the posts, the accounts, or that this is a summary."
});

const aiState = {
  availability: "unknown",
  summarizer: null,
  creating: null,
  progress: 0,
  error: ""
};
const aiSummaries = new Map();
let aiQueue = Promise.resolve();

function aiSupported() {
  return (
    typeof globalThis.Summarizer !== "undefined" &&
    typeof globalThis.Summarizer.availability === "function"
  );
}

function aiEnabled() {
  return Boolean(settings.enabled && settings.aiSummaries);
}

let availabilityRequest;

function refreshAiAvailability() {
  if (!aiEnabled()) {
    aiState.availability = "off";
    return Promise.resolve(aiState.availability);
  }
  if (!aiSupported()) {
    aiState.availability = "unsupported";
    return Promise.resolve(aiState.availability);
  }
  if (aiState.summarizer) {
    aiState.availability = "available";
    return Promise.resolve(aiState.availability);
  }
  if (availabilityRequest) return availabilityRequest;
  availabilityRequest = Promise.resolve()
    .then(() => globalThis.Summarizer.availability(SUMMARIZER_OPTIONS))
    .then((availability) => {
      aiState.availability = availability || "unavailable";
      return aiState.availability;
    })
    .catch((error) => {
      aiState.error = error?.message || String(error);
      aiState.availability = "unavailable";
      return aiState.availability;
    })
    .finally(() => {
      availabilityRequest = undefined;
    });
  return availabilityRequest;
}

function ensureSummarizer({ userActivated = false } = {}) {
  if (aiState.summarizer) return Promise.resolve(aiState.summarizer);
  if (aiState.creating) return aiState.creating;
  if (!aiSupported() || !aiEnabled()) return Promise.resolve(null);
  if (aiState.availability === "downloadable" && !userActivated) {
    return Promise.resolve(null);
  }
  if (aiState.availability === "unavailable" || aiState.availability === "unsupported") {
    return Promise.resolve(null);
  }

  aiState.creating = Promise.resolve()
    .then(() =>
      globalThis.Summarizer.create({
        ...SUMMARIZER_OPTIONS,
        monitor(monitor) {
          monitor.addEventListener("downloadprogress", (event) => {
            aiState.availability = "downloading";
            aiState.progress = Number(event.loaded) || 0;
            renderAiStatus();
          });
        }
      })
    )
    .then((summarizer) => {
      aiState.summarizer = summarizer;
      aiState.availability = "available";
      aiState.error = "";
      renderAiStatus();
      return summarizer;
    })
    .catch((error) => {
      aiState.error = error?.message || String(error);
      aiState.availability = "unavailable";
      renderAiStatus();
      return null;
    })
    .finally(() => {
      aiState.creating = null;
    });
  return aiState.creating;
}

function requestAiSummaries(items) {
  if (!aiEnabled() || !aiSupported()) return;
  refreshAiAvailability().then((availability) => {
    renderAiStatus();
    if (availability !== "available") return;
    ensureSummarizer().then((summarizer) => {
      if (!summarizer) return;
      for (const item of items) {
        if (aiSummaries.has(item.id)) continue;
        aiSummaries.set(item.id, { status: "pending", text: "" });
        aiQueue = aiQueue
          .then(() =>
            summarizer.summarize(briefSummaryInput(item), {
              context: item.topics.length
                ? `The reader follows these topics: ${item.topics.join(", ")}.`
                : undefined
            })
          )
          .then((text) => {
            const clean = String(text || "").replace(/\s+/g, " ").trim();
            if (!clean) throw new Error("Empty summary");
            aiSummaries.set(item.id, { status: "done", text: clean });
            patchStoryCards(item.id);
          })
          .catch((error) => {
            aiSummaries.set(item.id, {
              status: "error",
              text: "",
              error: error?.message || String(error)
            });
          });
      }
    });
  });
}

function enableAiSummaries() {
  ensureSummarizer({ userActivated: true }).then((summarizer) => {
    if (summarizer) requestAiSummaries(briefItems());
  });
}

function rememberBriefPost(post) {
  if (!post.key || !post.text) return;
  briefPostRegistry.delete(post.key);
  briefPostRegistry.set(post.key, post);
  while (briefPostRegistry.size > MAX_BRIEF_POSTS) {
    briefPostRegistry.delete(briefPostRegistry.keys().next().value);
  }
}

function briefItems() {
  return buildBrief([...briefPostRegistry.values()], settings);
}

function briefSummary(value, maxLength = 220) {
  const text = String(value || "").replace(/\s+/g, " ").trim();
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength).replace(/\s+\S*$/, "")}…`;
}

function briefScopeText() {
  return `Based on ${briefPostRegistry.size} eligible post${
    briefPostRegistry.size === 1 ? "" : "s"
  } Sift has loaded in this tab.`;
}

function aiStatusCopy() {
  switch (aiState.availability) {
    case "available":
      return {
        tone: "on",
        text: "Summaries are written on this device by Chrome’s built-in AI. Nothing leaves your browser."
      };
    case "downloading":
      return {
        tone: "busy",
        text: `Downloading Chrome’s on-device model… ${Math.round(
          Math.min(1, aiState.progress) * 100
        )}%`
      };
    case "downloadable":
      return {
        tone: "action",
        text: "AI summaries can run on this device. Chrome downloads its built-in model once; nothing is sent anywhere.",
        action: "Turn on AI summaries"
      };
    case "unavailable":
      return {
        tone: "muted",
        text: "This device can’t run Chrome’s on-device AI, so Brief shows the strongest post from each story."
      };
    case "unsupported":
      return {
        tone: "muted",
        text: "AI summaries need Chrome 138 or newer with built-in AI. Brief shows the strongest post from each story."
      };
    default:
      return null;
  }
}

function renderAiStatusInto(container) {
  container.replaceChildren();
  const copy = aiStatusCopy();
  container.hidden = !copy;
  container.dataset.siftTone = copy?.tone || "";
  if (!copy) return;
  const text = document.createElement("p");
  setText(text, copy.text);
  container.append(text);
  if (copy.tone === "busy") {
    const bar = document.createElement("progress");
    bar.max = 1;
    bar.value = Math.min(1, aiState.progress);
    bar.setAttribute("aria-label", "Model download progress");
    container.append(bar);
  }
  if (copy.action) {
    const button = makeButton("sift-ai-enable", copy.action, (element) => {
      element.disabled = true;
      setText(element, "Starting download…");
      enableAiSummaries();
    });
    button.title = "Requires Chrome 138+, 22 GB free disk, and a capable GPU or 16 GB RAM";
    container.append(button);
  }
}

function renderAiStatus() {
  document
    .querySelectorAll(".sift-ai-status")
    .forEach((container) => renderAiStatusInto(container));
  document.querySelectorAll(".sift-brief-item").forEach((card) => {
    const summary = aiSummaries.get(card.dataset.siftStory);
    if (summary?.status === "done") applyAiSummary(card, summary.text);
  });
}

function applyAiSummary(card, text) {
  const summary = card.querySelector(".sift-brief-summary");
  if (!summary) return;
  setText(summary, briefSummary(text, 320));
  card.classList.add("is-ai");
  const meta = card.querySelector(".sift-brief-meta");
  if (meta && !meta.querySelector(".sift-ai-badge")) {
    const badge = document.createElement("span");
    badge.className = "sift-ai-badge";
    setText(badge, "AI");
    badge.title = "Written on this device by Chrome’s built-in model";
    meta.append(badge);
  }
  const lead = card.querySelector(".sift-brief-lead");
  if (lead) lead.hidden = false;
}

function patchStoryCards(storyId) {
  const summary = aiSummaries.get(storyId);
  if (summary?.status !== "done") return;
  document
    .querySelectorAll(`.sift-brief-item[data-sift-story="${CSS.escape(storyId)}"]`)
    .forEach((card) => applyAiSummary(card, summary.text));
}

function renderBriefCard(item, index) {
  const card = document.createElement("article");
  card.className = "sift-brief-item";
  card.dataset.siftStory = item.id;

  const meta = document.createElement("span");
  meta.className = "sift-brief-meta";
  const topicLabel = item.topics.slice(0, 2).join(" · ");
  setText(
    meta,
    `${index + 1} · ${topicLabel || "Your feed"} · ${item.sourceCount} source${
      item.sourceCount === 1 ? "" : "s"
    }`
  );

  const summary = document.createElement("p");
  summary.className = "sift-brief-summary";
  setText(summary, briefSummary(item.summary));

  const lead = document.createElement("p");
  lead.className = "sift-brief-lead";
  lead.hidden = true;
  const leadPost = item.posts[0];
  setText(
    lead,
    `${leadPost?.handle ? `@${leadPost.handle}: ` : ""}${briefSummary(leadPost?.text, 140)}`
  );

  const sourceRow = document.createElement("div");
  sourceRow.className = "sift-brief-sources";
  for (const post of item.posts.slice(0, 5)) {
    if (!post.url) continue;
    const source = document.createElement("a");
    source.href = post.url;
    source.target = "_blank";
    source.rel = "noopener noreferrer";
    setText(source, post.handle ? `@${post.handle}` : "View post");
    sourceRow.append(source);
  }
  card.append(meta, summary, lead);
  if (sourceRow.childElementCount > 0) card.append(sourceRow);

  const cached = aiSummaries.get(item.id);
  if (cached?.status === "done") applyAiSummary(card, cached.text);
  return card;
}

function renderBriefList(list, items) {
  list.replaceChildren();
  if (items.length === 0) {
    const empty = document.createElement("div");
    empty.className = "sift-brief-empty";
    const emptyTitle = document.createElement("strong");
    setText(emptyTitle, "Your brief is still gathering signal");
    const emptyBody = document.createElement("p");
    setText(
      emptyBody,
      "Scroll your Sift feed to load eligible posts. Brief never fetches posts or sends content anywhere."
    );
    empty.append(emptyTitle, emptyBody);
    list.append(empty);
    return;
  }
  items.forEach((item, index) => list.append(renderBriefCard(item, index)));
}

function closeReviewDrawer() {
  document.querySelector(".sift-review-backdrop")?.remove();
  if (reviewEscapeHandler) {
    document.removeEventListener("keydown", reviewEscapeHandler);
    reviewEscapeHandler = undefined;
  }
}

function closeBriefDrawer() {
  document.querySelector(".sift-brief-backdrop")?.remove();
  if (briefEscapeHandler) {
    document.removeEventListener("keydown", briefEscapeHandler);
    briefEscapeHandler = undefined;
  }
}

function openBriefDrawer() {
  closeReviewDrawer();
  closeBriefDrawer();

  const items = briefItems();
  const backdrop = document.createElement("div");
  backdrop.className = "sift-brief-backdrop";
  backdrop.addEventListener("click", (event) => {
    if (event.target === backdrop) closeBriefDrawer();
  });

  const drawer = document.createElement("aside");
  drawer.className = "sift-brief-drawer";
  drawer.setAttribute("role", "dialog");
  drawer.setAttribute("aria-label", "Sift Brief");

  const header = document.createElement("header");
  const heading = document.createElement("div");
  const title = document.createElement("h2");
  setText(title, "Sift Brief");
  const subtitle = document.createElement("p");
  setText(subtitle, briefScopeText());
  heading.append(title, subtitle);
  const closeButton = makeButton("sift-brief-close", "Close", closeBriefDrawer);
  header.append(heading, closeButton);

  const aiStatus = document.createElement("div");
  aiStatus.className = "sift-ai-status";
  renderAiStatusInto(aiStatus);

  const list = document.createElement("div");
  list.className = "sift-brief-list";
  renderBriefList(list, items);

  const footer = document.createElement("footer");
  setText(
    footer,
    "Local summary · ranked by topic fit, independent sources, and activity"
  );
  drawer.append(header, aiStatus, list, footer);
  backdrop.append(drawer);
  briefEscapeHandler = (event) => {
    if (event.key === "Escape") closeBriefDrawer();
  };
  document.addEventListener("keydown", briefEscapeHandler);
  document.body.append(backdrop);
  closeButton.focus();
  requestAiSummaries(items);
}

/* ---------- Right rail ---------- */

function statsCopy() {
  const week = stats.weekCount;
  return `${week} post${week === 1 ? "" : "s"} filtered this week\n${
    stats.totalCount
  } all time`;
}

function buildRail() {
  const rail = document.createElement("aside");
  rail.className = "sift-rail";
  rail.setAttribute("aria-label", "Sift Brief");

  const header = document.createElement("header");
  const title = document.createElement("h2");
  setText(title, "Sift Brief");
  const subtitle = document.createElement("p");
  subtitle.className = "sift-rail-scope";
  header.append(title, subtitle);

  const aiStatus = document.createElement("div");
  aiStatus.className = "sift-ai-status";

  const list = document.createElement("div");
  list.className = "sift-brief-list sift-rail-list";

  const footer = document.createElement("footer");
  const statsLine = document.createElement("p");
  statsLine.className = "sift-rail-stats";
  statsLine.title = "Counted only on this device. Sift never reports anything.";
  const settingsButton = makeButton("sift-rail-settings", "Feed settings", openOptions);
  footer.append(statsLine, settingsButton);

  rail.append(header, aiStatus, list, footer);
  return rail;
}

function ensureRail(wanted) {
  const sidebar = document.querySelector('[data-testid="sidebarColumn"]');
  let rail = document.querySelector(".sift-rail");
  if (!wanted || !sidebar) {
    rail?.remove();
    return;
  }
  if (!rail || rail.parentElement !== sidebar) {
    rail?.remove();
    rail = buildRail();
    sidebar.append(rail);
  }

  const items = briefItems();
  const signature = `${briefPostRegistry.size}|${items.map((item) => item.id).join("|")}`;
  if (rail.dataset.siftSignature !== signature) {
    rail.dataset.siftSignature = signature;
    setText(rail.querySelector(".sift-rail-scope"), briefScopeText());
    renderBriefList(rail.querySelector(".sift-rail-list"), items);
  }
  setText(rail.querySelector(".sift-rail-stats"), statsCopy());
  renderAiStatusInto(rail.querySelector(".sift-ai-status"));
  requestAiSummaries(items);
}

/* ---------- Filtered-post counter (local only) ---------- */

function recordFiltered(postKey) {
  if (!postKey || countedHiddenKeys.has(postKey)) return;
  countedHiddenKeys.add(postKey);
  pendingFilteredCount += 1;
  clearTimeout(statsFlushTimer);
  statsFlushTimer = setTimeout(flushStats, STATS_FLUSH_MS);
}

function flushStats() {
  const local = localArea();
  const count = pendingFilteredCount;
  if (!local || count === 0) return;
  pendingFilteredCount = 0;
  local.get({ [STATS_KEY]: null }, (stored) => {
    if (chrome.runtime.lastError) {
      pendingFilteredCount += count;
      return;
    }
    stats = addToStats(stored[STATS_KEY], count);
    local.set({ [STATS_KEY]: stats }, () => {
      const rail = document.querySelector(".sift-rail-stats");
      if (rail) setText(rail, statsCopy());
    });
  });
}

/* ---------- Self-diagnostic banner ---------- */

function removeDiagnostic() {
  document.querySelector(".sift-diagnostic")?.remove();
}

function renderDiagnostic(problem) {
  const root = timelineRoot();
  if (!root) return;
  let banner = document.querySelector(".sift-diagnostic");
  if (!banner) {
    banner = document.createElement("div");
    banner.className = "sift-diagnostic";
    banner.setAttribute("role", "alert");
    const copy = document.createElement("div");
    const title = document.createElement("strong");
    const body = document.createElement("p");
    copy.append(title, body);
    const actions = document.createElement("div");
    actions.className = "sift-diagnostic-actions";
    actions.append(
      makeButton("sift-status-primary", "Reload page", () => location.reload()),
      makeButton("", "Check for update", () => {
        chrome.runtime.sendMessage({ type: "open-extensions" });
      }),
      makeButton("", "Dismiss", () => {
        diagnosticDismissedPath = location.pathname;
        removeDiagnostic();
      })
    );
    banner.append(copy, actions);
  }
  banner.dataset.siftProblem = problem;
  setText(
    banner.querySelector("strong"),
    problem === "unreadable"
      ? "Sift can see posts but can’t read them"
      : "Sift can’t see any posts here"
  );
  setText(
    banner.querySelector("p"),
    problem === "unreadable"
      ? "X may have changed its post layout. Sift is showing everything unfiltered until an update. Check chrome://extensions for a newer Sift version."
      : "Either the feed hasn’t loaded yet, or X changed its layout. If posts are visible on the page, Sift needs an update from chrome://extensions."
  );
  const status = root.querySelector(":scope > .sift-status-bar");
  if (status) status.after(banner);
  else root.prepend(banner);
}

function diagnoseFeed(articleCount, unreadableCount) {
  const problem =
    articleCount === 0
      ? "none"
      : unreadableCount === articleCount
        ? "unreadable"
        : "";
  if (!problem) {
    pendingDiagnostic = "";
    clearTimeout(diagnosticTimer);
    diagnosticTimer = undefined;
    removeDiagnostic();
    return;
  }
  if (diagnosticDismissedPath === location.pathname) return;
  pendingDiagnostic = problem;
  if (document.querySelector(".sift-diagnostic")) {
    renderDiagnostic(problem);
    return;
  }
  if (!diagnosticTimer) {
    diagnosticTimer = setTimeout(() => {
      diagnosticTimer = undefined;
      if (pendingDiagnostic) renderDiagnostic(pendingDiagnostic);
    }, DIAGNOSTIC_DELAY_MS);
  }
}

/* ---------- Filtered stacks + review drawer ---------- */

function reasonCategory(reason) {
  if (/promoted/i.test(reason)) return "ads";
  if (/repost/i.test(reason)) return "reposts";
  if (/quote/i.test(reason)) return "quotes";
  if (/blocked phrase/i.test(reason)) return "blocked phrases";
  if (/never-show|hidden account/i.test(reason)) return "blocked accounts";
  if (/doesn’t match|doesn't match|topic/i.test(reason)) return "off-topic";
  if (/external source|without an external/i.test(reason)) return "no source link";
  if (/maximum|per account|author/i.test(reason)) return "author limit";
  return "other";
}

function stackSummary(entries) {
  const counts = new Map();
  for (const entry of entries) {
    const category = reasonCategory(entry.reason);
    counts.set(category, (counts.get(category) || 0) + 1);
  }
  const ranked = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  const top = ranked.slice(0, 2);
  const remainder = ranked.slice(2).reduce((sum, [, count]) => sum + count, 0);
  const parts = top.map(([label, count]) => `${count} ${label}`);
  if (remainder > 0) parts.push(`${remainder} other`);
  return `${entries.length} post${entries.length === 1 ? "" : "s"} filtered · ${parts.join(" · ")}`;
}

function showEntry(entry) {
  entry.article.dataset.siftShowOnce = "true";
  closeReviewDrawer();
  scheduleApply();
}

function openReviewDrawer(stackId) {
  const entries = stackRegistry.get(stackId);
  if (!entries?.length) return;
  closeReviewDrawer();

  const backdrop = document.createElement("div");
  backdrop.className = "sift-review-backdrop";
  backdrop.addEventListener("click", (event) => {
    if (event.target === backdrop) closeReviewDrawer();
  });

  const drawer = document.createElement("aside");
  drawer.className = "sift-review-drawer";
  drawer.setAttribute("role", "dialog");
  drawer.setAttribute("aria-label", "Filtered posts");

  const header = document.createElement("header");
  const heading = document.createElement("div");
  const title = document.createElement("h2");
  setText(title, "Filtered posts");
  const subtitle = document.createElement("p");
  setText(subtitle, stackSummary(entries));
  heading.append(title, subtitle);
  const closeButton = makeButton("sift-review-close", "Close", closeReviewDrawer);
  header.append(heading, closeButton);

  const list = document.createElement("div");
  list.className = "sift-review-list";
  for (const entry of entries) {
    const item = document.createElement("article");
    item.className = "sift-review-item";
    const meta = document.createElement("span");
    setText(meta, entry.post.handle ? `@${entry.post.handle}` : "Unknown account");
    const reason = document.createElement("p");
    setText(reason, entry.reason);
    const preview = document.createElement("p");
    setText(preview, entry.post.text || "(no text)");
    const showButton = makeButton("", "Show this post", () => showEntry(entry));
    item.append(meta, reason, preview, showButton);
    list.append(item);
  }

  const footer = document.createElement("footer");
  const showAllButton = makeButton("", "Show all in this group", () => {
    for (const entry of entries) {
      entry.article.dataset.siftShowOnce = "true";
    }
    closeReviewDrawer();
    scheduleApply();
  });
  footer.append(showAllButton);

  drawer.append(header, list, footer);
  backdrop.append(drawer);
  reviewEscapeHandler = (event) => {
    if (event.key === "Escape") closeReviewDrawer();
  };
  document.addEventListener("keydown", reviewEscapeHandler);
  document.body.append(backdrop);
  closeButton.focus();
}

function handlePlaceholderAction(placeholder, article) {
  const stackId = placeholder.dataset.siftStackId;
  if (stackId) {
    openReviewDrawer(stackId);
    return;
  }
  article.dataset.siftShowOnce = "true";
  revealPost(article);
}

function revealPost(article) {
  article.classList.remove("sift-hidden-post");
  article.removeAttribute("data-sift-reason");
  const postKey = article.dataset.siftPostKey;
  for (const placeholder of article.parentElement?.querySelectorAll(
    ":scope > .sift-placeholder"
  ) || []) {
    if (
      placeholder === article.previousElementSibling ||
      (postKey && placeholder.dataset.siftPostKey === postKey)
    ) {
      placeholder.remove();
    }
  }
}

function collapsePost(article, reason) {
  if (article.dataset.siftShowOnce === "true") {
    revealPost(article);
    return;
  }

  article.classList.add("sift-hidden-post");
  article.dataset.siftReason = reason;
  recordFiltered(article.dataset.siftPostKey);

  let placeholder = Array.from(article.parentElement?.children || []).find(
    (element) =>
      element.classList.contains("sift-placeholder") &&
      element.dataset.siftPostKey === article.dataset.siftPostKey
  );
  if (!placeholder) placeholder = article.previousElementSibling;
  if (!placeholder?.classList.contains("sift-placeholder")) {
    placeholder = document.createElement("div");
    placeholder.className = "sift-placeholder";

    const reasonText = document.createElement("span");
    reasonText.className = "sift-placeholder-reason";
    placeholder.append(reasonText);

    const showButton = document.createElement("button");
    showButton.type = "button";
    setText(showButton, "Show this post");
    showButton.addEventListener("click", () => {
      handlePlaceholderAction(placeholder, article);
    });
    placeholder.append(showButton);
  }
  placeholder.dataset.siftPostKey = article.dataset.siftPostKey;
  placeholder.classList.remove(
    "sift-placeholder-stack",
    "sift-placeholder-stack-member",
    "sift-placeholder-preserved"
  );
  placeholder.style.removeProperty("height");
  delete placeholder.dataset.siftStackId;
  article.before(placeholder);

  const isStacked =
    placeholder.classList.contains("sift-placeholder-stack") ||
    placeholder.classList.contains("sift-placeholder-stack-member");
  if (!isStacked) {
    const reasonText = placeholder.querySelector(".sift-placeholder-reason");
    if (reasonText) setText(reasonText, `Filtered: ${reason}`);
    const showButton = placeholder.querySelector("button");
    if (showButton) setText(showButton, "Show");
  }
}

function renderStack(entries) {
  if (entries.length < 2) return;
  const first = entries[0];
  const last = entries.at(-1);
  const stackId = `${first.post.key}|${last.post.key}|${entries.length}`;
  stackRegistry.set(stackId, entries);

  const leader = first.article.previousElementSibling;
  if (!leader?.classList.contains("sift-placeholder")) return;
  leader.classList.add("sift-placeholder-stack");
  leader.dataset.siftStackId = stackId;
  setText(
    leader.querySelector(".sift-placeholder-reason"),
    stackSummary(entries)
  );
  setText(leader.querySelector("button"), "Review");

  for (const entry of entries.slice(1)) {
    const placeholder = entry.article.previousElementSibling;
    if (placeholder?.classList.contains("sift-placeholder")) {
      placeholder.classList.add("sift-placeholder-stack-member");
    }
  }
}

function groupHiddenPosts(decisions) {
  stackRegistry.clear();
  document.querySelectorAll(".sift-placeholder").forEach((placeholder) => {
    placeholder.classList.remove(
      "sift-placeholder-stack",
      "sift-placeholder-stack-member"
    );
    delete placeholder.dataset.siftStackId;
  });

  let run = [];
  const flush = () => {
    if (run.length === 0) return;
    if (run.length === 1) {
      const placeholder = run[0].article.previousElementSibling;
      if (placeholder?.classList.contains("sift-placeholder")) {
        const reasonText = placeholder.querySelector(
          ".sift-placeholder-reason"
        );
        if (reasonText) setText(reasonText, `Filtered: ${run[0].reason}`);
        const showButton = placeholder.querySelector("button");
        if (showButton) setText(showButton, "Show");
      }
    } else {
      renderStack(run);
    }
    run = [];
  };

  for (const decision of decisions) {
    if (decision.reason && decision.collapsed) {
      run.push(decision);
    } else {
      flush();
    }
  }
  flush();
}

/* ---------- Following tab ---------- */

function tryFollowingTab() {
  if (
    !settings.enabled ||
    !settings.defaultToFollowing ||
    followingAttempted ||
    location.pathname !== "/home"
  ) {
    return;
  }

  const tablist =
    document.querySelector('[data-testid="primaryColumn"] [role="tablist"]') ||
    document.querySelector('[role="tablist"]');
  const tabs = (tablist || document).querySelectorAll('[role="tab"]');
  const followingTab = pickFollowingTab(tabs, {
    allowPositional: Boolean(tablist)
  });

  if (followingTab) {
    followingAttempted = true;
    if (followingTab.getAttribute("aria-selected") !== "true") {
      followingTab.click();
    }
  }
}

/* ---------- Feed chrome ---------- */

function timelineRoot() {
  return (
    document.querySelector('[data-testid="primaryColumn"]') ||
    document.querySelector("main") ||
    document.body
  );
}

function removeStatusChrome() {
  document.querySelector(".sift-status-bar")?.remove();
  document.querySelector(".sift-empty-state")?.remove();
}

function pauseFiltering() {
  writeSettings({ enabled: false });
}

function updateFeedChrome(shown, filtered) {
  removeStatusChrome();
  if (!settings.enabled) return;

  const root = timelineRoot();
  if (!root) return;

  const feedInfo = getFeedInfo(settings.feedUrl);
  const usingList =
    feedInfo.isList &&
    feedInfo.isValid &&
    isActiveFeedPath(location.pathname, settings.feedUrl) &&
    location.pathname !== "/home";
  const needsBetterSource =
    shown === 0 &&
    filtered > 0 &&
    settings.requireTopicMatch &&
    !usingList;

  const status = document.createElement("div");
  status.className = "sift-status-bar";
  status.setAttribute("role", "status");

  const copy = document.createElement("div");
  const title = document.createElement("strong");
  setText(title, settings.profileName || "My Feed");
  const detail = document.createElement("span");
  setText(
    detail,
    filtered === 0
      ? `${shown} post${shown === 1 ? "" : "s"} showing`
      : `${shown} showing · ${filtered} filtered`
  );
  copy.append(title, detail);

  const actions = document.createElement("div");
  actions.className = "sift-status-actions";
  const briefButton = makeButton(
    "sift-status-primary sift-brief-button",
    `Brief${briefPostRegistry.size ? ` (${briefPostRegistry.size})` : ""}`,
    openBriefDrawer
  );
  actions.append(briefButton);
  actions.append(makeButton("", "Settings", openOptions));

  if (needsBetterSource) {
    actions.append(
      makeButton("sift-status-primary", "Add a List", () => {
        window.open("https://x.com/i/lists", "_blank", "noopener");
        openOptions();
      })
    );
  } else if (shown === 0 && filtered > 0) {
    actions.append(
      makeButton("sift-status-primary", "Show everything", pauseFiltering)
    );
  }

  status.append(copy, actions);
  root.prepend(status);

  if (shown === 0 && filtered > 0) {
    const empty = document.createElement("div");
    empty.className = "sift-empty-state";
    const heading = document.createElement("strong");
    const body = document.createElement("p");
    const row = document.createElement("div");

    if (needsBetterSource) {
      setText(heading, "Your rules are ready—X isn’t loading the right posts");
      setText(
        body,
        "Topic filters only keep posts X already shows. Create a focused List of accounts that cover your topics, paste that List URL in Settings, then open the List."
      );
      row.append(
        makeButton("sift-status-primary", "Create an X List", () => {
          window.open("https://x.com/i/lists", "_blank", "noopener");
        }),
        makeButton("", "Paste List in Settings", openOptions),
        makeButton("", "Pause filtering", pauseFiltering)
      );
    } else {
      setText(heading, "No matching posts in this batch");
      setText(
        body,
        "Sift filtered everything currently loaded. Scroll for more posts, widen your topics, or pause filtering."
      );
      row.append(
        makeButton("", "Open settings", openOptions),
        makeButton("sift-status-primary", "Pause filtering", pauseFiltering)
      );
    }

    empty.append(heading, body, row);
    status.after(empty);
  }
}

function clearInlineFiltering() {
  closeReviewDrawer();
  closeBriefDrawer();
  stackRegistry.clear();
  briefPostRegistry.clear();
  removeStatusChrome();
  removeDiagnostic();
  pendingDiagnostic = "";
  clearTimeout(diagnosticTimer);
  diagnosticTimer = undefined;
  ensureRail(false);
  document
    .querySelectorAll(".sift-placeholder")
    .forEach((placeholder) => placeholder.remove());
  document
    .querySelectorAll(".sift-post-preferences")
    .forEach((controls) => controls.remove());
  document
    .querySelectorAll("article.sift-hidden-post")
    .forEach(revealPost);
}

function cleanupOrphanedPlaceholders() {
  document.querySelectorAll(".sift-placeholder").forEach((placeholder) => {
    const article = placeholder.nextElementSibling;
    if (!article?.matches?.('article[data-testid="tweet"]')) {
      placeholder.remove();
      return;
    }
    const placeholderKey = placeholder.dataset.siftPostKey;
    const articleKey = article.dataset.siftPostKey;
    if (placeholderKey && articleKey && placeholderKey !== articleKey) {
      placeholder.remove();
    }
  });
}

function shouldCollapseNow(article, alreadyHidden) {
  const rect = article.getBoundingClientRect();
  // Never change layout above the viewport — that is what bounced the page.
  if (rect.bottom <= 0) return alreadyHidden;
  return true;
}

function applySettings() {
  if (isScrolling) return;

  syncTheme();
  document.documentElement.classList.toggle(
    "sift-distraction-free",
    settings.enabled && settings.distractionFree
  );

  ensureFeedShortcut();

  const shouldFilter =
    settings.enabled && isActiveFeedPath(location.pathname, settings.feedUrl);
  if (!shouldFilter) {
    clearInlineFiltering();
    return;
  }

  tryFollowingTab();
  cleanupOrphanedPlaceholders();

  const authorCounts = new Map();
  const rules = compileRules(settings);
  const topicLabels = topicLabelMap(settings.topicKeywords);
  const decisions = [];
  let shown = 0;
  let filtered = 0;
  let unreadable = 0;

  const articles = document.querySelectorAll('article[data-testid="tweet"]');
  articles.forEach((article) => {
    const post = extractPost(article);
    if (!post.handle && !post.text) unreadable += 1;
    if (article.dataset.siftPostKey !== post.key) {
      revealPost(article);
      article.dataset.siftPostKey = post.key;
      delete article.dataset.siftShowOnce;
    }

    const reason = getHideReason(post, settings, rules, authorCounts);
    const effectiveReason =
      article.dataset.siftShowOnce === "true" ? "" : reason;
    const alreadyHidden = article.classList.contains("sift-hidden-post");
    let collapsed = false;

    if (effectiveReason) {
      syncPostPreferenceActions(article, post, false);
      filtered += 1;
      if (shouldCollapseNow(article, alreadyHidden)) {
        collapsePost(article, effectiveReason);
        collapsed = true;
      } else {
        // Keep above-fold spam temporarily rather than yanking height upward.
        revealPost(article);
      }
    } else {
      revealPost(article);
      shown += 1;
      if (!reason) {
        rememberBriefPost(post);
        syncPostPreferenceActions(article, post, true, rules, topicLabels);
      } else {
        syncPostPreferenceActions(article, post, false);
      }
    }

    decisions.push({
      article,
      post,
      reason: effectiveReason,
      collapsed
    });
  });

  groupHiddenPosts(decisions);
  updateFeedChrome(shown, filtered);
  diagnoseFeed(articles.length, unreadable);
  ensureRail(settings.distractionFree);
}

function scheduleApply() {
  clearTimeout(applyTimer);
  applyTimer = setTimeout(applySettings, 80);
}

const SIFT_NODE_SELECTOR =
  ".sift-placeholder, .sift-post-preferences, .sift-feed-shortcut, .sift-settings-shortcut, .sift-review-backdrop, .sift-brief-backdrop, .sift-status-bar, .sift-empty-state, .sift-rail, .sift-toast, .sift-diagnostic";

function isSiftNode(node) {
  const element =
    node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
  return Boolean(
    element?.matches?.(SIFT_NODE_SELECTOR) ||
      element?.closest?.(SIFT_NODE_SELECTOR)
  );
}

function handleMutations(mutations) {
  const onlySiftChanges = mutations.every((mutation) => {
    if (isSiftNode(mutation.target)) return true;
    const changedNodes = [...mutation.addedNodes, ...mutation.removedNodes];
    return changedNodes.length > 0 && changedNodes.every(isSiftNode);
  });

  if (!onlySiftChanges) scheduleApply();
}

function loadSettings() {
  settingsStore.area.get(DEFAULT_SETTINGS, (stored) => {
    settings = { ...DEFAULT_SETTINGS, ...stored };
    followingAttempted = false;
    scheduleApply();
  });
  localArea()?.get({ [STATS_KEY]: null }, (stored) => {
    if (chrome.runtime.lastError) return;
    stats = normalizeStats(stored[STATS_KEY]);
    const rail = document.querySelector(".sift-rail-stats");
    if (rail) setText(rail, statsCopy());
  });
}

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName === "local" && changes[STATS_KEY]) {
    stats = normalizeStats(changes[STATS_KEY].newValue);
    const rail = document.querySelector(".sift-rail-stats");
    if (rail) setText(rail, statsCopy());
  }
  if (areaName !== settingsStore.name) return;

  const settingKeys = Object.keys(changes).filter((key) => key in DEFAULT_SETTINGS);
  if (settingKeys.length === 0) return;

  briefPostRegistry.clear();
  closeBriefDrawer();
  for (const key of settingKeys) {
    settings[key] = changes[key].newValue ?? DEFAULT_SETTINGS[key];
  }
  if (settingKeys.includes("aiSummaries") || settingKeys.includes("enabled")) {
    aiState.availability = "unknown";
  }
  followingAttempted = false;
  scheduleApply();
});

new MutationObserver(handleMutations).observe(document.documentElement, {
  childList: true,
  subtree: true
});

window.addEventListener(
  "scroll",
  () => {
    isScrolling = true;
    clearTimeout(scrollIdleTimer);
    scrollIdleTimer = setTimeout(() => {
      isScrolling = false;
      scheduleApply();
    }, 180);
  },
  { passive: true }
);

setInterval(() => {
  if (location.pathname !== lastPath) {
    lastPath = location.pathname;
    followingAttempted = false;
    diagnosticDismissedPath = "";
    scheduleApply();
  }
}, 500);

loadSettings();
