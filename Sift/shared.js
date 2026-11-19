(function initializeSiftCore(global) {
  const DEFAULT_SETTINGS = Object.freeze({
    enabled: true,
    profileName: "My Feed",
    feedUrl: "",
    topicKeywords: "",
    requireTopicMatch: false,
    defaultToFollowing: true,
    distractionFree: true,
    hidePromoted: true,
    hideReposts: false,
    hideQuotes: false,
    hidePostsWithoutLinks: false,
    maxPostsPerAuthor: 0,
    mutedKeywords: "",
    hiddenHandles: "",
    trustedHandles: "",
    aiSummaries: true
  });

  // Rate-limited, quota-bound sync storage is for user choices only. Counters
  // and diagnostics change constantly and must stay on this device.
  const STATS_KEY = "siftStats";
  const SYNC_ITEM_BYTES = 8192;
  const DIAGNOSTIC_DELAY_MS = 5000;

  function settingsArea() {
    const storage = globalThis.chrome?.storage;
    if (storage?.sync) return { name: "sync", area: storage.sync };
    return { name: "local", area: storage?.local };
  }

  function localArea() {
    return globalThis.chrome?.storage?.local;
  }

  const COMMON_MUTES = ["giveaway", "memecoin", "crypto airdrop", "follow for follow"];

  const STARTER_PACKS = Object.freeze([
    Object.freeze({
      id: "tesla",
      name: "Tesla",
      blurb: "Cars, FSD, Optimus, factories",
      topicKeywords: [
        "Tesla",
        "Model 3",
        "Model Y",
        "Model S",
        "Model X",
        "Cybertruck",
        "FSD",
        "Full Self-Driving",
        "Optimus",
        "Supercharger",
        "Gigafactory",
        "4680"
      ].join("\n"),
      trustedHandles: ["@Tesla"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 3
    }),
    Object.freeze({
      id: "spacex",
      name: "SpaceX",
      blurb: "Starship, Starlink, launches",
      topicKeywords: [
        "SpaceX",
        "Starship",
        "Starlink",
        "Falcon 9",
        "Falcon Heavy",
        "Dragon",
        "Raptor",
        "Starbase",
        "Crew Dragon"
      ].join("\n"),
      trustedHandles: ["@SpaceX", "@Starlink"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 3
    }),
    Object.freeze({
      id: "ai",
      name: "AI",
      blurb: "Models, agents, research labs",
      topicKeywords: [
        "AI",
        "artificial intelligence",
        "LLM",
        "GPT",
        "Claude",
        "Gemini",
        "OpenAI",
        "Anthropic",
        "DeepMind",
        "agents",
        "machine learning"
      ].join("\n"),
      trustedHandles: ["@OpenAI", "@AnthropicAI", "@GoogleDeepMind"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 3
    }),
    Object.freeze({
      id: "technology",
      name: "Technology",
      blurb: "Gadgets, software, big tech",
      topicKeywords: [
        "technology",
        "software",
        "Apple",
        "Google",
        "Microsoft",
        "Android",
        "iPhone",
        "chip",
        "semiconductor",
        "cloud computing"
      ].join("\n"),
      trustedHandles: ["@Apple", "@Google", "@Microsoft"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 3
    }),
    Object.freeze({
      id: "vc",
      name: "VC Funding",
      blurb: "Term sheets, rounds, founders",
      topicKeywords: [
        "venture capital",
        "Series A",
        "Series B",
        "seed round",
        "funding round",
        "term sheet",
        "startup funding",
        "IPO",
        "valuation"
      ].join("\n"),
      trustedHandles: ["@a16z", "@sequoia", "@ycombinator"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 3
    }),
    Object.freeze({
      id: "finance",
      name: "Finance",
      blurb: "Markets, Fed, earnings, banks",
      topicKeywords: [
        "stocks",
        "markets",
        "Federal Reserve",
        "interest rates",
        "earnings",
        "inflation",
        "Wall Street",
        "S&P 500",
        "bonds"
      ].join("\n"),
      trustedHandles: ["@WSJ", "@Bloomberg", "@CNBC"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 3
    }),
    Object.freeze({
      id: "sports",
      name: "Sports",
      blurb: "Scores, trades, game day",
      topicKeywords: [
        "NFL",
        "NBA",
        "MLB",
        "NHL",
        "Premier League",
        "March Madness",
        "transfer news",
        "playoffs",
        "World Cup"
      ].join("\n"),
      trustedHandles: ["@espn", "@NFL", "@NBA"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 4
    }),
    Object.freeze({
      id: "gaming",
      name: "Gaming",
      blurb: "Consoles, PC, esports, drops",
      topicKeywords: [
        "gaming",
        "PlayStation",
        "Xbox",
        "Nintendo",
        "Steam",
        "esports",
        "game release",
        "Game Pass",
        "Switch"
      ].join("\n"),
      trustedHandles: ["@PlayStation", "@Xbox", "@NintendoAmerica"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 3
    }),
    Object.freeze({
      id: "science",
      name: "Science",
      blurb: "Research, space, biology, physics",
      topicKeywords: [
        "science",
        "research paper",
        "physics",
        "biology",
        "astronomy",
        "NASA",
        "clinical trial",
        "peer reviewed",
        "Nobel"
      ].join("\n"),
      trustedHandles: ["@NASA", "@nature", "@ScienceMagazine"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 3
    }),
    Object.freeze({
      id: "climate",
      name: "Climate & Energy",
      blurb: "Clean power, grids, policy",
      topicKeywords: [
        "climate",
        "renewable energy",
        "solar power",
        "wind power",
        "nuclear energy",
        "EV charging",
        "grid",
        "carbon",
        "battery storage"
      ].join("\n"),
      trustedHandles: ["@IEA", "@UNFCCC"].join("\n"),
      mutedKeywords: COMMON_MUTES.join("\n"),
      maxPostsPerAuthor: 3
    })
  ]);

  function splitEntries(value) {
    return String(value || "")
      .split(/\r?\n/)
      .map((item) => item.trim())
      .filter(Boolean);
  }

  function normalizeTerm(value) {
    return String(value || "")
      .normalize("NFKC")
      .toLowerCase()
      .replace(/[^\p{L}\p{N}]+/gu, " ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function normalizeHandle(value) {
    return String(value || "").trim().toLowerCase().replace(/^@/, "");
  }

  function parseTerms(value) {
    return [...new Set(splitEntries(value).map(normalizeTerm).filter(Boolean))];
  }

  function parseHandles(value) {
    return new Set(
      splitEntries(value).map(normalizeHandle).filter(Boolean)
    );
  }

  function termMatches(normalizedText, normalizedTerm) {
    if (!normalizedText || !normalizedTerm) return false;
    return ` ${normalizedText} `.includes(` ${normalizedTerm} `);
  }

  function matchingTerm(normalizedText, terms) {
    return terms.find((term) => termMatches(normalizedText, term)) || "";
  }

  function mergeEntries(...values) {
    const merged = [];
    const seen = new Set();

    for (const entry of values.flatMap(splitEntries)) {
      const key = normalizeTerm(entry);
      if (!key || seen.has(key)) continue;
      seen.add(key);
      merged.push(entry);
    }

    return merged.join("\n");
  }

  function getStarterPack(id) {
    return STARTER_PACKS.find((pack) => pack.id === id) || null;
  }

  function mergeStarterTopics(...ids) {
    return mergeEntries(
      ...ids.map((id) => getStarterPack(id)?.topicKeywords || "")
    );
  }

  function mergeStarterHandles(...ids) {
    return mergeEntries(
      ...ids.map((id) => getStarterPack(id)?.trustedHandles || "")
    );
  }

  function starterPackIsApplied(pack, topicKeywords) {
    const existing = new Set(parseTerms(topicKeywords));
    const packTerms = parseTerms(pack.topicKeywords);
    if (packTerms.length === 0) return false;
    const matched = packTerms.filter((term) => existing.has(term)).length;
    return matched >= Math.min(3, packTerms.length);
  }

  function applyStarterPack(current, pack) {
    const next = {
      ...current,
      topicKeywords: mergeEntries(current.topicKeywords, pack.topicKeywords),
      mutedKeywords: mergeEntries(current.mutedKeywords, pack.mutedKeywords),
      trustedHandles: mergeEntries(
        current.trustedHandles,
        pack.trustedHandles
      ),
      requireTopicMatch: true,
      hidePromoted: true,
      maxPostsPerAuthor:
        Number(current.maxPostsPerAuthor) > 0
          ? current.maxPostsPerAuthor
          : pack.maxPostsPerAuthor
    };

    if (
      !current.profileName ||
      current.profileName === DEFAULT_SETTINGS.profileName
    ) {
      next.profileName = pack.name;
    }

    return next;
  }

  const TESLA_SPACEX_STARTER = Object.freeze({
    profileName: "Tesla + SpaceX",
    topicKeywords: mergeStarterTopics("tesla", "spacex"),
    requireTopicMatch: true,
    mutedKeywords: COMMON_MUTES.join("\n"),
    trustedHandles: mergeStarterHandles("tesla", "spacex"),
    hidePromoted: true,
    hideReposts: false,
    maxPostsPerAuthor: 3
  });

  function getFeedInfo(value) {
    const raw = String(value || "").trim();
    if (!raw) {
      return {
        url: "https://x.com/home",
        hasValue: false,
        isValid: true,
        isList: false,
        error: ""
      };
    }

    try {
      const withProtocol = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
      const url = new URL(withProtocol);
      const allowedHosts = new Set([
        "x.com",
        "www.x.com",
        "twitter.com",
        "www.twitter.com"
      ]);
      const isAllowedHost =
        url.protocol === "https:" &&
        allowedHosts.has(url.hostname) &&
        !url.username &&
        !url.password &&
        !url.port;
      const pathname = url.pathname.replace(/\/+$/, "");
      const isList =
        /^\/i\/lists\/\d+$/.test(pathname) ||
        /^\/[A-Za-z0-9_]{1,15}\/lists\/[^/]+$/.test(pathname);

      if (!isAllowedHost || !isList) {
        return {
          url: "https://x.com/home",
          hasValue: true,
          isValid: false,
          isList: false,
          error: "Paste an X List URL, such as https://x.com/i/lists/123."
        };
      }

      return {
        url: `https://x.com${pathname}`,
        pathname,
        hasValue: true,
        isValid: true,
        isList: true,
        error: ""
      };
    } catch {
      return {
        url: "https://x.com/home",
        hasValue: true,
        isValid: false,
        isList: false,
        error: "Paste a complete X List URL."
      };
    }
  }

  function isActiveFeedPath(pathname, feedUrl) {
    const currentPath = String(pathname || "").replace(/\/+$/, "") || "/";
    if (currentPath === "/home") return true;

    const feedInfo = getFeedInfo(feedUrl);
    return feedInfo.isList && currentPath === feedInfo.pathname;
  }

  function compileRules(settings) {
    return {
      topicKeywords: parseTerms(settings.topicKeywords),
      mutedKeywords: parseTerms(settings.mutedKeywords),
      trustedHandles: parseHandles(settings.trustedHandles),
      hiddenHandles: parseHandles(settings.hiddenHandles),
      limit: Number(settings.maxPostsPerAuthor)
    };
  }

  function getConflictingTerms(settings) {
    const wanted = new Set(parseTerms(settings.topicKeywords));
    return parseTerms(settings.mutedKeywords).filter((term) => wanted.has(term));
  }

  function getHideReason(post, settings, rules, authorCounts) {
    if (settings.hidePromoted && post.isPromoted) {
      return "Promoted post";
    }

    if (post.handle && rules.hiddenHandles.has(post.handle)) {
      return `Never-show account @${post.handle}`;
    }

    const blockedTerm = matchingTerm(post.normalizedText, rules.mutedKeywords);
    if (blockedTerm) {
      return `Blocked phrase “${blockedTerm}”`;
    }

    if (settings.hideReposts && post.isRepost) {
      return "Repost";
    }

    if (settings.hideQuotes && post.isQuote) {
      return "Quote post";
    }

    const isPriorityAccount =
      post.handle && rules.trustedHandles.has(post.handle);
    if (
      settings.requireTopicMatch &&
      rules.topicKeywords.length > 0 &&
      !isPriorityAccount &&
      !matchingTerm(post.normalizedText, rules.topicKeywords)
    ) {
      return `Doesn’t match your “${settings.profileName || "My Feed"}” topics`;
    }

    if (settings.hidePostsWithoutLinks && !post.hasExternalLink) {
      return "Post without an external source link";
    }

    if (
      post.handle &&
      Number.isFinite(rules.limit) &&
      rules.limit > 0
    ) {
      const count = (authorCounts.get(post.handle) || 0) + 1;
      authorCounts.set(post.handle, count);
      if (count > rules.limit) {
        return `More than ${rules.limit} posts from @${post.handle}`;
      }
    }

    return "";
  }

  const BRIEF_STOP_WORDS = new Set([
    "about",
    "after",
    "again",
    "also",
    "been",
    "before",
    "being",
    "from",
    "have",
    "into",
    "just",
    "more",
    "most",
    "over",
    "that",
    "their",
    "there",
    "they",
    "this",
    "through",
    "today",
    "very",
    "what",
    "when",
    "where",
    "which",
    "with",
    "would",
    "your"
  ]);

  function parseBriefMetric(value) {
    const text = String(value || "")
      .trim()
      .toLowerCase()
      .replace(/,/g, "");
    const match = text.match(/(\d+(?:\.\d+)?)\s*([kmb])?/);
    if (!match) return 0;
    const multiplier = { k: 1e3, m: 1e6, b: 1e9 }[match[2]] || 1;
    return Math.round(Number(match[1]) * multiplier);
  }

  function briefTokens(value) {
    return normalizeTerm(value)
      .split(" ")
      .filter(
        (token) =>
          token.length >= 4 &&
          !BRIEF_STOP_WORDS.has(token) &&
          !/^\d+$/.test(token)
      );
  }

  function briefMatchedTopics(post, rules) {
    return rules.topicKeywords.filter((topic) =>
      termMatches(post.normalizedText, topic)
    );
  }

  function postsBelongTogether(left, right) {
    const leftLinks = new Set(left.externalUrls || []);
    if ((right.externalUrls || []).some((url) => leftLinks.has(url))) return true;

    const leftTokens = new Set(left.briefTokens || briefTokens(left.text));
    const sharedTokens = (right.briefTokens || briefTokens(right.text)).filter(
      (token) => leftTokens.has(token)
    );
    if (sharedTokens.length >= 2) return true;

    const leftTopics = new Set(left.matchedTopics || []);
    const sharesTopic = (right.matchedTopics || []).some((topic) =>
      leftTopics.has(topic)
    );
    return sharesTopic && sharedTokens.length >= 1;
  }

  function briefPostScore(post, trustedHandles) {
    const engagement =
      Number(post.engagement?.likes || 0) +
      Number(post.engagement?.reposts || 0) * 2 +
      Number(post.engagement?.replies || 0) * 1.25 +
      Math.sqrt(Number(post.engagement?.views || 0));
    const trusted = trustedHandles.has(post.handle) ? 2.5 : 0;
    return Math.log10(engagement + 1) + trusted;
  }

  function buildBrief(posts, settings, limit = 5) {
    const rules = compileRules(settings);
    const prepared = [...posts]
      .filter((post) => post?.key && post?.text)
      .map((post) => ({
        ...post,
        briefTokens: briefTokens(post.text),
        matchedTopics: briefMatchedTopics(post, rules)
      }));
    const clusters = [];

    for (const post of prepared) {
      const cluster = clusters.find((candidate) =>
        candidate.posts.some((existing) => postsBelongTogether(existing, post))
      );
      if (cluster) cluster.posts.push(post);
      else clusters.push({ posts: [post] });
    }

    return clusters
      .map((cluster) => {
        const handles = new Set(
          cluster.posts.map((post) => post.handle).filter(Boolean)
        );
        const topics = [
          ...new Set(cluster.posts.flatMap((post) => post.matchedTopics))
        ];
        const rankedPosts = [...cluster.posts].sort(
          (left, right) =>
            briefPostScore(right, rules.trustedHandles) -
            briefPostScore(left, rules.trustedHandles)
        );
        const representative = rankedPosts[0];
        const score =
          rankedPosts.reduce(
            (sum, post) => sum + briefPostScore(post, rules.trustedHandles),
            0
          ) +
          Math.max(0, handles.size - 1) * 3 +
          Math.max(0, cluster.posts.length - handles.size) * 0.25;

        return {
          id: rankedPosts.map((post) => post.key).sort().join("|"),
          summary: representative.text,
          topics,
          sourceCount: handles.size || cluster.posts.length,
          postCount: cluster.posts.length,
          score,
          posts: rankedPosts
        };
      })
      .sort((left, right) => right.score - left.score)
      .slice(0, Math.max(1, Number(limit) || 5));
  }

  function briefSummaryInput(item) {
    return (item?.posts || [])
      .slice(0, 5)
      .map((post) => {
        const text = String(post.text || "").replace(/\s+/g, " ").trim();
        return post.handle ? `@${post.handle}: ${text}` : text;
      })
      .filter(Boolean)
      .join("\n\n");
  }

  function topicLabelMap(topicKeywords) {
    const labels = new Map();
    for (const entry of splitEntries(topicKeywords)) {
      const key = normalizeTerm(entry);
      if (key && !labels.has(key)) labels.set(key, entry);
    }
    return labels;
  }

  function suggestMutePhrases(post, settings, limit = 3) {
    const rules = compileRules(settings);
    const normalizedText = normalizeTerm(post?.text || "");
    const words = String(post?.text || "").split(/\s+/);
    const seen = new Set();
    const suggestions = [];

    for (const rawWord of words) {
      const word = rawWord.replace(/^[^\p{L}\p{N}#@]+|[^\p{L}\p{N}]+$/gu, "");
      if (!word || word.startsWith("@") || /^https?:/i.test(word)) continue;
      const key = normalizeTerm(word);
      if (
        key.length < 4 ||
        seen.has(key) ||
        BRIEF_STOP_WORDS.has(key) ||
        /^\d+$/.test(key) ||
        !termMatches(normalizedText, key)
      ) {
        continue;
      }
      // Never offer to mute something the user explicitly asked to see.
      if (rules.topicKeywords.some((topic) => termMatches(topic, key))) continue;
      if (rules.mutedKeywords.includes(key)) continue;
      seen.add(key);
      suggestions.push(word.replace(/^#/, ""));
      if (suggestions.length >= limit) break;
    }

    return suggestions;
  }

  // X orders the home tabs as For you, Following, then pinned Lists in every
  // language, so position is a reliable fallback when the label isn't English.
  function pickFollowingTab(tabs, { allowPositional = true } = {}) {
    const list = Array.from(tabs || []);
    const labelled = list.find(
      (tab) => String(tab?.textContent || "").trim().toLowerCase() === "following"
    );
    if (labelled) return labelled;
    return allowPositional && list.length >= 2 ? list[1] : null;
  }

  function weekStart(date = new Date()) {
    const day = new Date(date);
    day.setHours(0, 0, 0, 0);
    const offset = (day.getDay() + 6) % 7;
    day.setDate(day.getDate() - offset);
    const pad = (value) => String(value).padStart(2, "0");
    return `${day.getFullYear()}-${pad(day.getMonth() + 1)}-${pad(day.getDate())}`;
  }

  function normalizeStats(stats, now = new Date()) {
    const currentWeek = weekStart(now);
    const week = Number(stats?.week === currentWeek ? stats.weekCount : 0) || 0;
    return {
      week: currentWeek,
      weekCount: Math.max(0, week),
      totalCount: Math.max(0, Number(stats?.totalCount) || 0)
    };
  }

  function addToStats(stats, count, now = new Date()) {
    const current = normalizeStats(stats, now);
    const amount = Math.max(0, Number(count) || 0);
    return {
      ...current,
      weekCount: current.weekCount + amount,
      totalCount: current.totalCount + amount
    };
  }

  function exportSettings(settings, version = "") {
    const payload = {};
    for (const key of Object.keys(DEFAULT_SETTINGS)) {
      if (key === "enabled") continue;
      payload[key] = settings?.[key] ?? DEFAULT_SETTINGS[key];
    }
    return JSON.stringify(
      {
        app: "Sift",
        version,
        exportedAt: new Date().toISOString(),
        settings: payload
      },
      null,
      2
    );
  }

  function importSettings(text) {
    let parsed;
    try {
      parsed = JSON.parse(String(text || ""));
    } catch {
      return { error: "That file is not valid JSON." };
    }
    const source =
      parsed && typeof parsed === "object" && parsed.settings &&
      typeof parsed.settings === "object"
        ? parsed.settings
        : parsed;
    if (!source || typeof source !== "object" || Array.isArray(source)) {
      return { error: "That file does not contain Sift settings." };
    }

    const settings = {};
    const applied = [];
    const ignored = [];
    for (const [key, value] of Object.entries(source)) {
      if (!(key in DEFAULT_SETTINGS) || key === "enabled") {
        ignored.push(key);
        continue;
      }
      const expected = typeof DEFAULT_SETTINGS[key];
      if (expected === "boolean" && typeof value === "boolean") {
        settings[key] = value;
      } else if (
        expected === "number" &&
        Number.isInteger(Number(value)) &&
        value !== "" &&
        value !== null
      ) {
        settings[key] = Number(value);
      } else if (expected === "string" && typeof value === "string") {
        settings[key] = value;
      } else if (expected === "string" && Array.isArray(value)) {
        settings[key] = value.map(String).join("\n");
      } else {
        ignored.push(key);
        continue;
      }
      applied.push(key);
    }

    if (applied.length === 0) {
      return { error: "No recognizable Sift settings were found in that file." };
    }
    return { settings, applied, ignored };
  }

  function oversizedSyncFields(settings) {
    const encoder = new TextEncoder();
    return Object.keys(DEFAULT_SETTINGS).filter((key) => {
      const size = encoder.encode(key + JSON.stringify(settings?.[key] ?? "")).length;
      return size > SYNC_ITEM_BYTES - 200;
    });
  }

  function isDarkColor(cssColor) {
    const value = String(cssColor || "").trim().toLowerCase();
    let red;
    let green;
    let blue;
    let alpha = 1;
    const rgb = value.match(
      /rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:[\s,/]+([\d.]+%?))?\s*\)/
    );
    const hex = value.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/);
    if (rgb) {
      [red, green, blue] = [rgb[1], rgb[2], rgb[3]].map(Number);
      if (rgb[4] !== undefined) {
        alpha = rgb[4].endsWith("%") ? Number.parseFloat(rgb[4]) / 100 : Number(rgb[4]);
      }
    } else if (hex) {
      const digits = hex[1].length === 3 ? hex[1].split("").map((d) => d + d) : hex[1].match(/../g);
      [red, green, blue] = digits.map((pair) => Number.parseInt(pair, 16));
    } else {
      return false;
    }
    if (!(alpha > 0.5)) return false;
    const luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255;
    return luminance < 0.5;
  }

  global.SiftCore = Object.freeze({
    STATS_KEY,
    SYNC_ITEM_BYTES,
    DIAGNOSTIC_DELAY_MS,
    settingsArea,
    localArea,
    briefMatchedTopics,
    briefSummaryInput,
    topicLabelMap,
    suggestMutePhrases,
    pickFollowingTab,
    weekStart,
    normalizeStats,
    addToStats,
    exportSettings,
    importSettings,
    oversizedSyncFields,
    isDarkColor,
    DEFAULT_SETTINGS,
    STARTER_PACKS,
    TESLA_SPACEX_STARTER,
    splitEntries,
    normalizeTerm,
    normalizeHandle,
    parseTerms,
    parseHandles,
    termMatches,
    matchingTerm,
    mergeEntries,
    getStarterPack,
    starterPackIsApplied,
    applyStarterPack,
    getFeedInfo,
    isActiveFeedPath,
    compileRules,
    getConflictingTerms,
    getHideReason,
    parseBriefMetric,
    briefTokens,
    buildBrief
  });
})(globalThis);
