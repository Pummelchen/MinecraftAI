(function () {
  function applyGlassTheme() {
    document.documentElement.dataset.theme = 'glass';
    window.dispatchEvent(new CustomEvent('pummelchen-theme-change', { detail: { theme: 'glass' } }));
    window.dispatchEvent(new Event('resize'));
  }

  applyGlassTheme();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', applyGlassTheme, { once: true });
  }
})();
