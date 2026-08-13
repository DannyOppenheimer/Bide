/**
 * Renders `/trip` invitations for browsers that do not open the Universal Link
 * in Bide. Server rendering also provides per-invite Open Graph metadata because
 * link-preview fetchers do not execute client-side JavaScript.
 */

const APP_SCHEME_URL = 'bide://invite';
const SITE = 'https://trybide.app';

/** Maximum destination length displayed in page and preview headlines. */
const MAX_DESTINATION = 90;

export function onRequestGet({ request }) {
  const url = new URL(request.url);
  const params = url.searchParams;

  const destination = clamp(params.get('to'), MAX_DESTINATION);
  if (!destination) {
    return Response.redirect(SITE + '/', 302);
  }

  const senderName = clamp(params.get('from'), 40);
  const isTracking = params.get('watch') === '1';
  const scheduledFor = params.get('at');

  // Use Cloudflare's time zone for previews; the browser replaces it with local time.
  const timeZone = request.cf?.timezone || 'UTC';
  const schedule = scheduleText(scheduledFor, isTracking, timeZone, Date.now());

  const html = page({
    isTracking,
    scheduledFor,
    schedule,
    headline: headlineText(destination, senderName, isTracking),
    appURL: APP_SCHEME_URL + url.search,
    mapURL: mapLink(params.get('lat'), params.get('lng'), destination),
    canonical: SITE + url.pathname + url.search,
  });

  return new Response(html, {
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      // Keep previews and immediate page visits consistent without retaining stale times.
      'Cache-Control': 'public, max-age=300',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    },
  });
}

// Formatting
// These helpers are serialized into the page and run on both server and client.
// Keep them self-contained, with no imports or module-scope references.

/** Formats a scheduled time, falling back to ASAP copy when absent or expired. */
function scheduleText(iso, isTracking, timeZone, nowMs) {
  const asap = isTracking ? 'As soon as they can' : 'As soon as everyone can';
  if (!iso) return asap;

  const date = new Date(iso);
  if (Number.isNaN(date.getTime()) || date.getTime() <= nowMs) return asap;

  const dayKey = (value) =>
    new Intl.DateTimeFormat('en-CA', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).format(value);

  const now = new Date(nowMs);
  const tomorrow = new Date(nowMs + 86400000);

  let day;
  if (dayKey(date) === dayKey(now)) {
    day = 'Today';
  } else if (dayKey(date) === dayKey(tomorrow)) {
    day = 'Tomorrow';
  } else {
    const month = new Intl.DateTimeFormat('en-US', { timeZone, month: 'long' }).format(date);
    const number = Number(
      new Intl.DateTimeFormat('en-US', { timeZone, day: 'numeric' }).format(date)
    );
    const teen = number % 100 >= 11 && number % 100 <= 13;
    const suffix = teen ? 'th' : { 1: 'st', 2: 'nd', 3: 'rd' }[number % 10] || 'th';
    day = month + ' ' + number + suffix;
  }

  const time = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hour: 'numeric',
    minute: '2-digit',
  }).format(date);

  return day + ' · ' + time;
}

/** Formats a duration with the same wording as `BideFormat.duration`. */
function durationText(seconds) {
  const value = Math.max(0, seconds);
  if (value < 60) return 'Under a minute';

  const minutes = Math.round(value / 60);
  if (minutes < 60) return minutes + ' minute' + (minutes === 1 ? '' : 's');

  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  return remainder === 0 ? hours + ' hr' : hours + ' hr ' + remainder + ' min';
}

/** Distinguishes meetup invitations from watcher-only tracking links. */
function headlineText(destination, senderName, isTracking) {
  const who = senderName || 'Someone';
  return isTracking
    ? `${who} invites you to track their trip to ${destination}`
    : `${who} invites you to meet at ${destination}`;
}

// Page rendering

function page(model) {
  const {
    isTracking,
    scheduledFor,
    schedule,
    headline,
    appURL,
    mapURL,
    canonical,
  } = model;

  const description = isTracking
    ? `Arriving ${schedule}. Open Bide to watch their ETA count down — you are not joining the trip, and none of your location is shared.`
    : `Arriving ${schedule}. Open Bide to see everyone's live ETA, so whoever is closest knows to leave last.`;

  const footnote = isTracking
    ? "You'll see their ETA, not their location. Nothing about where you are is shared."
    : 'Bide computes ETAs on your device. Only your arrival time is ever shared.';

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(headline)}</title>
<meta name="description" content="${esc(description)}">
<meta name="theme-color" content="#1D1D1F">
<meta name="color-scheme" content="dark">
<link rel="canonical" href="${esc(canonical)}">
<link rel="icon" href="/favicon-32x32.png" type="image/png" sizes="32x32">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">

<!-- Messages uses this metadata to render the invitation preview. -->
<meta property="og:type" content="website">
<meta property="og:site_name" content="Bide">
<meta property="og:title" content="${esc(headline)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${esc(canonical)}">
<meta property="og:image" content="${SITE}/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Bide">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(headline)}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="${SITE}/og.png">
<style>
  /* Values mirror BideTheme. */
  :root {
    --background: #1D1D1F;
    --surface: #2C2C2E;
    --control: #333333;
    --primary-text: #FFFFFF;
    --secondary-text: #8E8E93;
    --inverse-text: #0A0A0A;
    --watching: #5E9CFF;
    --border: rgba(255, 255, 255, 0.18);
    --card-radius: 20px;
    --control-radius: 10px;
  }

  * { box-sizing: border-box; }

  html, body { min-height: 100%; }

  body {
    margin: 0;
    min-height: 100vh;
    min-height: 100svh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1.5rem;
    background: var(--background);
    color: var(--primary-text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Helvetica, Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
    -webkit-text-size-adjust: 100%;
  }

  /* Expand the transcript tile's layout to page size. */
  .tile {
    width: min(27rem, 100%);
    padding: 2rem 1.75rem 1.75rem;
    border-radius: var(--card-radius);
    background: var(--surface);
    text-align: center;
    animation: rise 420ms cubic-bezier(0.2, 0.7, 0.3, 1) both;
  }

  @keyframes rise {
    from { opacity: 0; transform: translateY(0.75rem); }
    to   { opacity: 1; transform: none; }
  }

  .mark {
    display: block;
    width: 6.5rem;
    height: auto;
    margin: 0 auto;
    overflow: visible;
  }

  .badge {
    display: inline-block;
    margin: 1.5rem 0 0;
    padding: 0.25rem 0.55rem;
    border-radius: 999px;
    background: rgba(94, 156, 255, 0.16);
    color: var(--watching);
    font-size: 0.6875rem;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }

  h1 {
    margin: 1rem 0 0;
    font-size: clamp(1.4rem, 5.5vw, 1.75rem);
    font-weight: 650;
    line-height: 1.22;
    letter-spacing: -0.02em;
    overflow-wrap: anywhere;
  }

  .schedule {
    margin-top: 1.5rem;
    padding: 0.875rem 1rem;
    border-radius: var(--control-radius);
    background: var(--control);
  }

  .schedule-label {
    margin: 0;
    color: var(--secondary-text);
    font-size: 0.6875rem;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }

  .schedule-value {
    margin: 0.25rem 0 0;
    font-size: 1.25rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .schedule-countdown {
    margin: 0.15rem 0 0;
    color: var(--secondary-text);
    font-size: 0.8125rem;
  }

  .schedule-countdown:empty { display: none; }

  .actions {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    margin-top: 1.25rem;
  }

  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 2.75rem;
    padding: 0 1rem;
    border: 1px solid var(--border);
    border-radius: var(--control-radius);
    color: var(--primary-text);
    font-size: 1.0625rem;
    font-weight: 600;
    text-decoration: none;
    transition: background-color 160ms ease, transform 160ms ease;
  }

  .button--primary {
    border-color: transparent;
    background: var(--primary-text);
    color: var(--inverse-text);
  }

  .button:active { transform: translateY(1px); }
  .button:not(.button--primary):hover { background: rgba(255, 255, 255, 0.08); }
  .button--primary:hover { background: #FFFFFF; }

  .button:focus-visible {
    outline: 2px solid var(--primary-text);
    outline-offset: 3px;
  }

  .footnote {
    margin: 1.25rem 0 0;
    color: var(--secondary-text);
    font-size: 0.8125rem;
    line-height: 1.45;
  }

  .about {
    margin: 0.75rem 0 0;
    color: var(--secondary-text);
    font-size: 0.8125rem;
    line-height: 1.45;
  }

  .about a {
    color: var(--secondary-text);
    text-underline-offset: 2px;
  }

  .about a:hover { color: var(--primary-text); }

  @media (prefers-reduced-motion: reduce) {
    .tile { animation: none; }
    .button { transition: none; }
  }
</style>
</head>
<body>
  <main class="tile">
    <svg class="mark" viewBox="0 0 112 12" role="img" aria-label="Bide">
      <path d="M5 6H107" stroke="currentColor" stroke-width="2"/>
      <circle cx="5" cy="6" r="5" fill="currentColor"/>
      <circle cx="39" cy="6" r="5" fill="currentColor"/>
      <circle cx="73" cy="6" r="5" fill="currentColor"/>
      <circle cx="107" cy="6" r="5" fill="currentColor"/>
    </svg>

    ${isTracking ? '<p class="badge">Tracking</p>' : ''}

    <h1>${esc(headline)}</h1>

    <div class="schedule">
      <p class="schedule-label">Arriving</p>
      <p
        class="schedule-value"
        data-schedule
        ${scheduledFor ? `data-at="${esc(scheduledFor)}"` : ''}
        data-tracking="${isTracking ? '1' : '0'}"
      >${esc(schedule)}</p>
      <p class="schedule-countdown" data-countdown></p>
    </div>

    <div class="actions">
      <a class="button button--primary" href="${esc(appURL)}">Open in Bide</a>
      ${mapURL ? `<a class="button" href="${esc(mapURL)}" target="_blank" rel="noopener noreferrer">See it on a map</a>` : ''}
    </div>

    <p class="footnote">${esc(footnote)}</p>
    <p class="about">
      Bide is how you know when to leave.
      <a href="${SITE}/">What is this?</a>
    </p>
  </main>

<script>
  (function () {
    var element = document.querySelector('[data-schedule]');
    var countdown = document.querySelector('[data-countdown]');
    if (!element) return;

    // Replace the server's request-derived time zone with the browser's local zone.
    var timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    var iso = element.getAttribute('data-at');
    var isTracking = element.getAttribute('data-tracking') === '1';

    ${scheduleText.toString()}
    ${durationText.toString()}

    function render() {
      element.textContent = scheduleText(iso, isTracking, timeZone, Date.now());

      if (!iso) return;

      // Show a countdown only within 12 hours, when it adds useful detail.
      var remaining = (new Date(iso).getTime() - Date.now()) / 1000;
      var soon = remaining > 0 && remaining < 12 * 3600;
      countdown.textContent = soon ? 'in ' + durationText(remaining) : '';
    }

    render();
    window.setInterval(render, 30000);
  })();
</script>
</body>
</html>`;
}

// Input handling

/** Escapes query-string values for use in HTML text and attributes. */
function esc(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** Normalizes whitespace, truncates to a limit, and returns null when empty. */
function clamp(value, limit) {
  if (!value) return null;
  const trimmed = value.replace(/\s+/g, ' ').trim();
  if (!trimmed) return null;
  return trimmed.length > limit ? trimmed.slice(0, limit - 1) + '…' : trimmed;
}

/** Builds a map link for the invitation's destination, never a user's position. */
function mapLink(lat, lng, destination) {
  const latitude = Number(lat);
  const longitude = Number(lng);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;

  return (
    'https://maps.apple.com/?ll=' +
    latitude +
    ',' +
    longitude +
    '&q=' +
    encodeURIComponent(destination)
  );
}
