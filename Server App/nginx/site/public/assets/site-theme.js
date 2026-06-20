(function () {
  const storageKey = 'pummelchen-site-theme';
  const defaultTheme = 'glass';
  const validThemes = new Set(['current', 'glass']);

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

  document.documentElement.dataset.theme = storedTheme();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', buildSwitcher);
  } else {
    buildSwitcher();
  }
})();
