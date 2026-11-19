// The page of a site in an app's frame, as Potok remembers it and puts it in
// a link (`?page=`): a path of the site itself, never another site's.
//
// `sitePath(page, home)` takes what a site reports, or what a link carries,
// and the address the description gave its frame. It returns the path,
// query and fragment on the same origin as `home`, or null for anything else:
// another host, `//host`, a scheme, a backslash, control characters, or more
// than MAX_PAGE characters.

export const MAX_PAGE = 1024

const CONTROL = /[\u0000-\u001f\u007f]/

export function sitePath(page, home) {
  if (typeof page !== "string" || page.length === 0 || page.length > MAX_PAGE) return null
  if (!page.startsWith("/") || page.startsWith("//") || page.includes("\\") || CONTROL.test(page)) {
    return null
  }

  let origin

  try {
    origin = new URL(home).origin
    if (!/^https?:$/.test(new URL(home).protocol)) return null
  } catch (_error) {
    return null
  }

  try {
    const url = new URL(page, origin)
    if (url.origin !== origin) return null
    return url.pathname + url.search + url.hash
  } catch (_error) {
    return null
  }
}

// The path of the frame's own address, to tell when the reader is back on it.
export function homePath(home) {
  try {
    const url = new URL(home)
    return url.pathname + url.search + url.hash
  } catch (_error) {
    return null
  }
}
