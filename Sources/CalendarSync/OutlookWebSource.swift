import AppKit
import CalendarSyncCore
import Foundation
import WebKit

/// Reads a client's Outlook / Microsoft 365 calendar through a built-in browser window,
/// for accounts that can't be added to Calendar.app.
///
/// The user signs in once in the window (MFA included). Each sync reloads the Outlook
/// calendar week view in the background and records the JSON that Outlook's own web app
/// downloads. The week view leaves out meeting bodies (and so the join links), so the
/// meetings are then loaded in full through Outlook's own service, signed in the same way
/// Outlook's own requests are. `OutlookWebParser` turns all of that into events. Nothing is
/// sent anywhere else.
///
/// EXPERIMENTAL: this depends on how Outlook on the web loads its data, which Microsoft can
/// change at any time. If a sync can't find calendar data, the copies are left untouched.
@MainActor
final class OutlookWebSource: NSObject, ObservableObject {
    /// Change if the client uses a different Outlook host (e.g. outlook.office365.com).
    static let host = "https://outlook.office.com"

    @Published private(set) var needsSignIn = false

    let sourceID: UUID
    private let webView: WKWebView
    private var window: NSWindow?
    private var captured: [Data] = []
    private var lastCaptureAt = Date.distantPast
    private var isFetching = false

    init(sourceID: UUID) {
        self.sourceID = sourceID

        let config = WKWebViewConfiguration()
        // One persistent cookie store per source, so several Outlook clients can each stay
        // signed in.
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: sourceID)
        config.userContentController.addUserScript(
            WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 860), configuration: config)
        // Outlook may refuse browsers it doesn't recognise; present as Safari.
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        super.init()
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "calsync")
    }

    /// Releases the web view so its stored sign-in can be deleted.
    func tearDown() {
        window?.close()
        window = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: - Sign-in window

    /// Shows Outlook in a normal window so the user can sign in or check what's loaded.
    func showWindow(title: String) {
        let window = self.window ?? makeWindow()
        window.title = "Outlook – \(title)"
        if webView.url == nil {
            webView.load(URLRequest(url: Self.weekURL(for: Date())))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.window = window
        return window
    }

    // MARK: - Fetching

    func fetch(from start: Date, to end: Date) async -> SourceFetchResult {
        guard !isFetching else { return .failure("Already reading Outlook") }
        // Loading would navigate away from whatever the user is doing in the window
        // (e.g. signing in), so wait until it's closed.
        if window?.isVisible == true {
            return .failure("Outlook window is open. Close it after signing in to sync.")
        }
        isFetching = true
        defer { isFetching = false }

        captured = []
        var onScreen: [SourceEvent] = []
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        // The week view only loads one week, so read every week the sync window touches.
        // Outlook ignores the date in the URL and opens the current week, so load that and
        // move on with Outlook's own "next week" button.
        for (index, weekStart) in Self.weekStarts(from: start, to: end).enumerated() {
            let before = captured.count
            lastCaptureAt = .distantPast
            if index == 0 {
                webView.load(URLRequest(url: Self.weekURL(for: weekStart)))
            } else {
                // The first week's data arrives before Outlook has finished starting up; a
                // click that early can move the page without its data ever being requested.
                if index == 1 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                if await !clickNextWeek() {
                    return .failure("Couldn't move to the next week in Outlook.")
                }
            }
            // Check against the whole week: Outlook loads all of it, including days already
            // past (on a weekend the work week view shows the week just ended).
            let week = calendar.dateInterval(of: .weekOfYear, for: weekStart)
            let weekFrom = week?.start ?? weekStart, weekTo = week?.end ?? end
            var loaded = await waitForCalendarData(after: before, from: weekFrom, to: weekTo)

            if isSignInPage(webView.url) {
                needsSignIn = true
                return .failure("Signed out of Outlook. Open the Outlook window to sign in again.")
            }
            // Outlook doesn't always fetch a week in a way we can capture (it can come from a
            // background worker). The meetings it shows on the page are always there.
            if !loaded {
                let shown = await meetingsOnScreen(from: weekFrom, to: weekTo)
                onScreen += shown
                loaded = !shown.isEmpty
            }
            // No meeting in the week almost always means its data didn't load (Outlook can
            // answer with another week). Fail, so existing copies are left alone.
            if !loaded {
                return .failure("Couldn't read the Outlook calendar (no calendar data loaded).")
            }
        }

        needsSignIn = false
        let itemIDs = OutlookWebParser.itemIDs(fromPayloads: captured)
        let details = await loadDetails(itemIDs: itemIDs)
        // Captured data first: it has more detail (meeting links, declined, all day).
        var seen: Set<String> = []
        let events = (OutlookWebParser.events(fromPayloads: captured, details: details) + onScreen)
            .map { event -> SourceEvent in
                var event = event
                event.title = event.title.trimmingCharacters(in: .whitespaces)
                event.key = OutlookWebParser.screenKey(title: event.title, start: event.start)
                return event
            }
            .filter { seen.insert($0.key).inserted }
            .filter { $0.end > start && $0.start < end }
        let withLinks = events.filter { $0.meetingURL != nil }.count
        NSLog("Calendar Sync: Outlook \(events.count) meetings, \(details.count) detail responses, \(withLinks) with a meeting link")
        return .success(events)
    }

    /// Loads the meetings in full (body, join link). Returns the raw responses, or nothing if
    /// Outlook didn't make a service call the page could copy its sign-in from; the meetings
    /// are then copied without those details.
    private func loadDetails(itemIDs: [String]) async -> [Data] {
        guard !itemIDs.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(Self.detailsScript, arguments: ["ids": itemIDs], in: nil, in: .page) { result in
                let texts = (try? result.get()) as? [String] ?? []
                continuation.resume(returning: texts.map { Data($0.utf8) })
            }
        }
    }

    /// Reads the meetings Outlook shows for `[from, to)` from the page, waiting up to 10 s
    /// for them to render.
    private func meetingsOnScreen(from: Date, to: Date) async -> [SourceEvent] {
        let script = "[...document.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label'))"
        for _ in 0..<10 {
            let labels = (try? await webView.evaluateJavaScript(script) as? [String]) ?? []
            let events = OutlookWebParser.events(fromScreenLabels: labels)
                .filter { $0.start >= from && $0.start < to }
            if !events.isEmpty { return events }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return []
    }

    /// Waits until Outlook has downloaded a meeting starting in `[from, to)` and gone quiet
    /// for 3 s, up to 15 s. Returns whether that data arrived.
    private func waitForCalendarData(after before: Int, from: Date, to: Date) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        var checked = before
        var loaded = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if isSignInPage(webView.url) { return false }
            if !loaded, captured.count > checked {
                loaded = OutlookWebParser.events(fromPayloads: Array(captured[checked...]))
                    .contains { $0.start >= from && $0.start < to }
                checked = captured.count
            }
            if loaded, Date().timeIntervalSince(lastCaptureAt) > 3 { return true }
        }
        return loaded
    }

    /// Clicks Outlook's "next week" button, waiting up to 5 s for it to render. Clicked once
    /// only: each click moves another week.
    private func clickNextWeek() async -> Bool {
        let script = """
        (() => {
          const button = [...document.querySelectorAll('button[aria-label]')]
            // The label can carry the target dates: "Go to next week October 26–30, 2026".
            .find(b => /^(go to )?next (work ?)?week\\b/i.test(b.getAttribute('aria-label').trim()));
          if (!button) return false;
          button.click();
          return true;
        })()
        """
        for _ in 0..<5 {
            if (try? await webView.evaluateJavaScript(script) as? Bool) == true { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private func isSignInPage(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.contains("login.microsoftonline.com") || host.contains("login.live.com")
            || host.contains("login.microsoft.com")
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["body"] as? String else { return }
        captured.append(Data(text.utf8))
        lastCaptureAt = Date()
    }

    // MARK: - URLs

    static func weekURL(for date: Date) -> URL {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return URL(string: "\(host)/calendar/view/week/\(c.year!)/\(c.month!)/\(c.day!)")!
    }

    static func weekStarts(from start: Date, to end: Date) -> [Date] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        var weeks: [Date] = []
        var cursor = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        while cursor < end {
            weeks.append(max(cursor, start))
            cursor = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor)!
        }
        return weeks
    }

    /// Wraps `fetch` and `XMLHttpRequest` in the page and forwards responses from calendar
    /// endpoints to the app. Also remembers the URL and headers of Outlook's own service calls
    /// (which carry its sign-in), for `detailsScript`. Read-only: requests are passed through
    /// unchanged.
    static let captureScript = #"""
    (function () {
      if (window.__calsync) return;
      window.__calsync = true;
      // graphql carries the weeks after the first one. SaveCalendarView only stores which
      // view is shown and has no events.
      const RX = /^(?!.*savecalendarview).*(calendarview|finditem|calendaritem|startupdata|\/events|graphql)/i;
      const MAX = 8 * 1024 * 1024;
      function send(url, text) {
        try {
          if (!text || text.length > MAX) return;
          const c = text.trimStart()[0];
          if (c !== '{' && c !== '[') return;
          window.webkit.messageHandlers.calsync.postMessage({ url: String(url), body: text });
        } catch (e) {}
      }
      function remember(url, headers) {
        try {
          if (!/\/service\.svc/i.test(String(url))) return;
          window.__calsyncService = { url: new URL(String(url), location.href).href, headers: headers };
        } catch (e) {}
      }
      const origFetch = window.fetch;
      if (origFetch) {
        window.__calsyncFetch = origFetch;
        window.fetch = function (input, init) {
          const p = origFetch.apply(this, arguments);
          try {
            const url = typeof input === 'string' ? input : (input && input.url) || '';
            if (RX.test(url)) p.then(r => r.clone().text()).then(t => send(url, t)).catch(() => {});
            const headers = {};
            if (input && input.headers) new Headers(input.headers).forEach((v, k) => { headers[k] = v; });
            if (init && init.headers) new Headers(init.headers).forEach((v, k) => { headers[k] = v; });
            remember(url, headers);
          } catch (e) {}
          return p;
        };
      }
      const open = XMLHttpRequest.prototype.open;
      const xsend = XMLHttpRequest.prototype.send;
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__calsyncURL = url;
        this.__calsyncHeaders = {};
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        try { if (this.__calsyncHeaders) this.__calsyncHeaders[String(name).toLowerCase()] = String(value); } catch (e) {}
        return setHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        remember(this.__calsyncURL, this.__calsyncHeaders || {});
        if (RX.test(String(this.__calsyncURL || ''))) {
          this.addEventListener('load', function () {
            try {
              if (this.responseType === '' || this.responseType === 'text') send(this.__calsyncURL, this.responseText);
              else if (this.responseType === 'json') send(this.__calsyncURL, JSON.stringify(this.response));
            } catch (e) {}
          });
        }
        return xsend.apply(this, arguments);
      };
    })();
    """#
}

extension OutlookWebSource {
    /// Runs in the page (`callAsyncJavaScript`, with `ids`): asks Outlook's service for the
    /// meetings in full, as Outlook itself does when a meeting is opened, reusing the sign-in
    /// headers of its last service call. Sends the request in the body and, if Outlook refuses
    /// that, in the `x-owa-urlpostdata` header that newer Outlook versions use. Returns the
    /// response texts.
    static let detailsScript = #"""
    const svc = window.__calsyncService;
    if (!svc || !ids || !ids.length) return [];
    const url = new URL(svc.url);
    url.searchParams.set('action', 'GetItem');
    url.searchParams.delete('n');
    const base = {};
    for (const [k, v] of Object.entries(svc.headers || {})) {
      if (!/^(content-length|content-type|action|x-owa-urlpostdata|x-owa-actionname|x-owa-actionid)$/i.test(k)) base[k] = v;
    }
    base['action'] = 'GetItem';
    base['content-type'] = 'application/json; charset=utf-8';
    const doFetch = window.__calsyncFetch || window.fetch;
    async function post(headers, body) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 20000);
      try {
        const r = await doFetch.call(window, url.href, {
          method: 'POST', headers, body, credentials: 'include', signal: controller.signal,
        });
        return r.ok ? await r.text() : null;
      } catch (e) {
        return null;
      } finally {
        clearTimeout(timer);
      }
    }
    const out = [];
    const size = 10;
    for (let i = 0; i < ids.length; i += size) {
      const request = JSON.stringify({
        __type: 'GetItemJsonRequest:#Exchange',
        Header: { __type: 'JsonRequestHeaders:#Exchange', RequestServerVersion: 'Exchange2013' },
        Body: {
          __type: 'GetItemRequest:#Exchange',
          ItemShape: { __type: 'ItemResponseShape:#Exchange', BaseShape: 'AllProperties', BodyType: 'HTML' },
          ItemIds: ids.slice(i, i + size).map(id => ({ __type: 'ItemId:#Exchange', Id: id })),
        },
      });
      let text = await post(base, request);
      if (text === null) {
        text = await post(Object.assign({}, base, { 'x-owa-urlpostdata': encodeURIComponent(request) }), '');
      }
      if (text) out.push(text);
    }
    return out;
    """#
}

/// Avoids the retain cycle WKUserContentController creates with its message handlers.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: OutlookWebSource?

    init(_ target: OutlookWebSource) { self.target = target }

    // WebKit delivers script messages on the main thread.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message) }
    }
}
