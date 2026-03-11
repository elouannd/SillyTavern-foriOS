/**
 * ios-init.js
 * Detects the iOS nodejs-mobile environment and applies mobile optimisations:
 *  - Adds `st-ios` class to <body> to activate ios-overrides.css
 *  - Injects the iOS stylesheet link
 *  - Disables unnecessary features that don't apply on-device
 *
 * This script is loaded at the end of <body> in index.html (iOS build only).
 * On non-iOS environments it's a no-op.
 */
(function () {
    // Detect iOS: Capacitor sets window.Capacitor, and we confirm localhost origin
    const isIOS = typeof window !== 'undefined' &&
        (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') &&
        /iPad|iPhone|iPod/.test(navigator.userAgent || '');

    // Also detect via navigator.standalone (added to home screen PWA) or Capacitor
    const isCapacitor = typeof window.Capacitor !== 'undefined';

    if (!isIOS && !isCapacitor) return;

    // Add iOS class to body for CSS targeting
    document.body.classList.add('st-ios');

    // Inject the iOS CSS override stylesheet if not already present
    if (!document.getElementById('st-ios-css')) {
        const link = document.createElement('link');
        link.id = 'st-ios-css';
        link.rel = 'stylesheet';
        link.href = '/css/ios-overrides.css';
        document.head.appendChild(link);
    }

    // Prevent context menus on long-press (native iOS behaviour interferes with ST menus)
    document.addEventListener('contextmenu', function (e) {
        // Allow on text content for copy/paste, block elsewhere
        if (e.target.closest('textarea, input, .mes_text')) return;
        e.preventDefault();
    }, { passive: false });

    // Viewport height fix: account for iOS dynamic viewport (virtual keyboard)
    function setViewportHeight() {
        const vh = window.visualViewport ? window.visualViewport.height : window.innerHeight;
        document.documentElement.style.setProperty('--real-vh', `${vh * 0.01}px`);
    }
    setViewportHeight();
    if (window.visualViewport) {
        window.visualViewport.addEventListener('resize', setViewportHeight);
    } else {
        window.addEventListener('resize', setViewportHeight);
    }

    console.log('[SillyTavern iOS] Mobile init complete');
})();
