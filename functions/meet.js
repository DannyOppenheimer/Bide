/**
 * Redirects legacy `/meet` invitations to `/trip` without losing their query
 * payload. Use a temporary redirect so browsers do not cache this compatibility
 * route permanently.
 */
export function onRequestGet({ request }) {
  const url = new URL(request.url);
  url.pathname = '/trip';

  return new Response(null, {
    status: 302,
    headers: {
      Location: url.pathname + url.search,
      'Cache-Control': 'no-store',
    },
  });
}
