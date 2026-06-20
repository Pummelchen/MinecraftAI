(function () {
  const storageKey = 'pummelchen-site-theme';
  const defaultTheme = 'glass';
  const validThemes = new Set(['current', 'glass', 'glass2']);

  function storedTheme() {
    try {
      const value = window.localStorage.getItem(storageKey);
      return validThemes.has(value) ? value : defaultTheme;
    } catch {
      return defaultTheme;
    }
  }

  function applyTheme(theme) {
    const next = validThemes.has(theme) ? theme : defaultTheme;
    document.documentElement.dataset.theme = next;
    try {
      window.localStorage.setItem(storageKey, next);
    } catch {
      // Theme persistence is optional; the selected theme still applies for this page view.
    }
    document.querySelectorAll('[data-theme-choice]').forEach(button => {
      button.setAttribute('aria-pressed', String(button.dataset.themeChoice === next));
    });
    window.dispatchEvent(new CustomEvent('pummelchen-theme-change', { detail: { theme: next } }));
    window.dispatchEvent(new Event('resize'));
  }

  function buildSwitcher() {
    if (document.querySelector('.theme-switcher')) return;
    const nav = document.createElement('nav');
    nav.className = 'theme-switcher';
    nav.setAttribute('aria-label', 'Website theme');
    nav.innerHTML = [
      ['current', 'Current'],
      ['glass', 'Glass'],
      ['glass2', 'Glass 2'],
    ].map(([theme, label]) => (
      `<button type="button" data-theme-choice="${theme}" aria-pressed="false">${label}</button>`
    )).join('');
    nav.addEventListener('click', event => {
      const button = event.target.closest('[data-theme-choice]');
      if (!button) return;
      applyTheme(button.dataset.themeChoice);
    });
    document.body.appendChild(nav);
    applyTheme(storedTheme());
  }

  const glowSelector = [
    'header',
    'main > section',
    '.stat',
    '.chart-card',
    '.version-card',
    '.update-card',
    '.update-countdown',
    '.update-activity',
    '.run-block',
    '.manual-update',
    '.card',
    '.download',
    '.table-shell',
    '.sheet-grid'
  ].join(',');

  let pendingPointer = null;
  let glowFrame = 0;

  function updateGlass2PointerGlow() {
    glowFrame = 0;
    if (!pendingPointer || document.documentElement.dataset.theme !== 'glass2') return;
    const pointer = pendingPointer;
    document.querySelectorAll(glowSelector).forEach(node => {
      const rect = node.getBoundingClientRect();
      const x = pointer.x - rect.left;
      const y = pointer.y - rect.top;
      if (x < -80 || y < -80 || x > rect.width + 80 || y > rect.height + 80) return;
      node.style.setProperty('--mouse-x', `${Math.max(0, Math.min(rect.width, x))}px`);
      node.style.setProperty('--mouse-y', `${Math.max(0, Math.min(rect.height, y))}px`);
    });
  }

  function wireGlass2PointerGlow() {
    document.addEventListener('pointermove', event => {
      if (document.documentElement.dataset.theme !== 'glass2') return;
      pendingPointer = { x: event.clientX, y: event.clientY };
      if (!glowFrame) glowFrame = window.requestAnimationFrame(updateGlass2PointerGlow);
    }, { passive: true });
  }

  function flashLiveUpdatedElements() {
    if (document.documentElement.dataset.theme !== 'glass2') return;
    document.querySelectorAll('[data-live-stat], [data-live-metric], #liveStatus, #serverVersionsGrid, #modsCount').forEach(node => {
      node.classList.remove('live-update-flash');
      void node.offsetWidth;
      node.classList.add('live-update-flash');
    });
  }

  window.addEventListener('pummelchen-live-data-updated', flashLiveUpdatedElements);

  document.documentElement.dataset.theme = storedTheme();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
      buildSwitcher();
      wireGlass2PointerGlow();
    });
  } else {
    buildSwitcher();
    wireGlass2PointerGlow();
  }
})();
