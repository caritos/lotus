const PLACEHOLDER = "__BUILD_ID__";

/**
 * The build id the server wrote into index.html (YYYYMMDD-<short commit>), or "dev" when the
 * meta tag is missing, empty or still holds the placeholder (the Vite dev server).
 */
export function buildId(): string {
  const content = document.querySelector<HTMLMetaElement>('meta[name="build-id"]')?.content.trim();
  return content && content !== PLACEHOLDER ? content : "dev";
}

/** Page footer with the build id; rendered on every route. */
export function Footer() {
  return (
    <footer className="site-footer">
      <span className="build-id">Build {buildId()}</span>
    </footer>
  );
}
