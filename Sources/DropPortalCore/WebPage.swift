//
//  WebPage.swift
//  DropPortalCore
//
//  The one page the phone loads: inline CSS and JS, nothing from a CDN.
//  Served by DropPortalServer on the local network as /?t=<token>; every
//  POST carries the token as X-DropPortal-Token. While a card is dragged the
//  page talks to PeekChannel over a WebSocket on port 8788 (hello with the
//  token first), so the Mac can show what is coming; uploads never wait on it.
//

enum WebPage {
    /// The page's policy. `socketHost` is the host the phone reached the page
    /// by; the peek socket on that host is allowed, nothing else is.
    static func contentSecurityPolicy(socketHost: String?) -> String {
        let socket = socketHost.map { " ws://\($0):\(PeekChannel.defaultPort)" } ?? ""
        return "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; " +
            "img-src 'self' blob: data:; manifest-src 'self'; media-src blob:; connect-src 'self'\(socket); base-uri 'none'; form-action 'none'"
    }

    /// The host part of a `Host` header when it is a plain name or IPv4
    /// address, so it can go into a header unescaped; nil otherwise.
    static func socketHost(_ header: String?) -> String? {
        guard let header else { return nil }
        let host = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard (1...253).contains(host.utf8.count),
              host.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
                  || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x2D })
        else { return nil }
        return host
    }

    /// The page with the crossing effect and its colour the Mac has chosen
    /// (`data-tint`: `#RRGGBB` or `rainbow`; the page derives its tones as `PortalTones` does).
    static func html(effect: PortalEffect, tint: PortalTint? = nil) -> String {
        let tint = tint ?? .defaultTint(for: effect)
        return page.replacingOccurrences(of: ##"<html lang="en" data-effect="portal" data-tint="#2F6BFF">"##,
                                             with: #"<html lang="en" data-effect="\#(effect.rawValue)" data-tint="\#(tint.stored)">"#)
    }

    /// The template with one row per phone shortcut; the script adds the token to each link.
    private static let page = template.replacingOccurrences(of: "<!--shortcut-rows-->", with: PhoneShortcut.allCases.map { kind in
        #"<div class="rec"><div class="rtext"><div class="rname">\#(escape(kind.title))</div><div class="schint">\#(escape(kind.hint))</div></div><a class="btn small" data-shortcut="\#(kind.path)">Add</a></div>"#
    }.joined()).replacingOccurrences(of: "<!--webgl-->", with: WebGLEffect.block + WebSkyEffect.block + WebCourierEffect.block)

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static let template = #"""
<!doctype html>
<html lang="en" data-effect="portal" data-tint="#2F6BFF">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Drop Portal">
<meta name="theme-color" content="#0b0b0f">
<meta name="referrer" content="no-referrer">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" type="image/png" href="/apple-touch-icon.png">
<title>Drop Portal</title>
<style>
:root { color-scheme: dark; --bg:#0b0b0f; --card:#1a1a22; --line:#2a2a35; --text:#f2f2f5; --dim:#8d8d99; --accent:#5b8cff; --ok:#3ecf8e; --bad:#ff5d5d; }
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { margin:0; background:var(--bg); color:var(--text); font:16px/1.4 -apple-system, system-ui, sans-serif; overscroll-behavior:none; }
body { padding: calc(env(safe-area-inset-top) + 16px) 16px calc(env(safe-area-inset-bottom) + 24px); overflow-x:hidden; }
header { display:flex; align-items:baseline; justify-content:space-between; margin-bottom:6px; }
h1 { font-size:28px; margin:0; letter-spacing:-0.02em; }
.pick { display:flex; align-items:center; justify-content:center; gap:10px; width:100%; height:64px; border-radius:18px; background:var(--accent); color:#fff; font-size:19px; font-weight:600; border:0; position:relative; overflow:hidden; }
.pick input { position:absolute; inset:0; opacity:0; font-size:0; }
.pick:active { transform:scale(.98); }
.grid { display:grid; grid-template-columns:repeat(2, 1fr); gap:12px; margin:16px 0; }
.card { position:relative; aspect-ratio:1; border-radius:18px; background:var(--card); overflow:hidden; touch-action:pan-y; user-select:none; -webkit-user-select:none; will-change:transform; box-shadow:0 6px 18px rgba(0,0,0,.35); }
.card img, .card video { width:100%; height:100%; object-fit:cover; display:block; pointer-events:none; }
.card .doc { width:100%; height:100%; display:flex; align-items:center; justify-content:center; font-size:22px; font-weight:700; color:var(--dim); letter-spacing:.04em; }
.card .name { position:absolute; left:0; right:0; bottom:0; padding:18px 10px 8px; font-size:12px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; background:linear-gradient(transparent, rgba(0,0,0,.75)); }
.card .bar { position:absolute; left:10px; right:10px; top:10px; height:6px; border-radius:3px; background:rgba(255,255,255,.18); overflow:hidden; display:none; }
.card .bar i { display:block; height:100%; width:0; background:var(--accent); transition:width .15s; }
.card .badge { position:absolute; inset:0; display:none; align-items:center; justify-content:center; font-size:15px; font-weight:600; background:rgba(0,0,0,.55); text-align:center; padding:12px; }
.card.sending .bar { display:block; }
.card.sending, .card.sent { opacity:.75; }
.card.sent .badge { display:flex; color:var(--ok); }
.card.failed .badge { display:flex; color:var(--bad); }
.card.sent .badge { flex-direction:column; gap:5px; }
.kname { display:block; max-width:100%; font-size:12px; font-weight:500; color:#fff; white-space:nowrap; overflow:hidden; }
.kname .kl { display:inline-block; white-space:pre; }
.kname .ext { opacity:.62; }
.sr { position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0 0 0 0); white-space:nowrap; }
.card.back { transition: transform .25s cubic-bezier(.2,.8,.2,1), opacity .25s; }
.card .flare { position:absolute; inset:0; pointer-events:none; opacity:0; transition:opacity .25s; background:linear-gradient(90deg, rgba(228,238,255,.95), rgba(150,190,255,.35) 55%, transparent); }
.card.drag .flare { transition:none; }
.card.gone { transition: opacity .3s, transform .3s; opacity:0; transform:scale(.85); }
.empty { color:var(--dim); text-align:center; padding:28px 0 8px; font-size:14px; }
/* Portal intensity: --pg is the glow gain, --pw its width at full progress. JS twin: PORTAL below. */
:root { --pg:2.4; --pw:42vw; }
/* The effect's colour (setTint below, PortalTones on the Mac): --fx the saturated glow, --fx2 the nearly white core, --fx3 the second tone. */
:root { --fx:47,107,255; --fx2:221,230,255; --fx3:75,47,255; }
/* The page dims away from the edge while a card is dragged, so the light reads. Below the dragged card (z 5). */
.veil { position:fixed; inset:0; z-index:4; pointer-events:none; opacity:0; background:radial-gradient(ellipse 140% 95% at 0 50%, transparent 22%, rgba(0,0,0,.62) 78%); transition:opacity .25s ease-out; will-change:opacity; }
.veil.live { transition:none; }
.portal { position:fixed; left:0; top:0; bottom:0; width:var(--pw); z-index:10; pointer-events:none; opacity:0; transform:scaleX(.35); transform-origin:0 50%; transition:opacity .3s ease-out, transform .3s ease-out; will-change:opacity, transform; }
.portal::before { content:""; position:absolute; inset:0; background:radial-gradient(ellipse 100% 70% at 0 50%, rgba(var(--fx2),calc(.6*var(--pg))), rgba(var(--fx),calc(.34*var(--pg))) 40%, rgba(var(--fx3),calc(.1*var(--pg))) 70%, rgba(var(--fx3),0)); }
.portal::after { content:""; position:absolute; left:0; top:4%; bottom:4%; width:4px; background:linear-gradient(transparent, #fff 25%, #fff 75%, transparent); box-shadow:0 0 28px 8px rgba(var(--fx),.95), 0 0 70px 20px rgba(var(--fx3),.45); }
.portal.live { transition:none; }
.portal.flash { animation:portalFlash .1s cubic-bezier(.22,0,.58,1); }
@keyframes portalFlash { 0% { opacity:.65; transform:scaleX(1.35); } 32% { opacity:.95; transform:scaleX(1.6); } 100% { opacity:0; transform:scaleX(1.85); } }
@keyframes portalFade { 0% { opacity:1; } 100% { opacity:0; } }
.sparks { position:fixed; left:0; top:0; width:100%; height:100%; z-index:11; pointer-events:none; display:none; }
/* Effects: <html data-effect> picks the edge and the card's light. Portal light is the default above. */
.portal .fx { position:absolute; display:none; pointer-events:none; }
/* The rift: a tall lens of light on the edge, and rays fanning from it. */
.portal .rift { display:block; left:-8vw; top:1%; bottom:1%; width:16vw; border-radius:50%; background:radial-gradient(ellipse 50% 50% at 50% 50%, rgba(255,255,255,.95), rgba(var(--fx),.75) 38%, rgba(var(--fx),0) 72%); }
.portal .rays { display:block; left:0; top:-30%; width:100%; height:160%; background:repeating-conic-gradient(from 0deg at 0 50%, rgba(var(--fx2),0) 0deg 4deg, rgba(var(--fx2),.5) 5.5deg, rgba(var(--fx2),0) 7deg 11deg); -webkit-mask:radial-gradient(ellipse 100% 45% at 0 50%, #000 8%, transparent 80%); mask:radial-gradient(ellipse 100% 45% at 0 50%, #000 8%, transparent 80%); }
html[data-effect=wormhole] .portal .rift, html[data-effect=plane] .portal .rift, html[data-effect=plane] .portal .rays, html[data-effect=beam] .portal .rays { display:none; }
.card.blob { border-radius:46%; transition:border-radius .25s; }
.strip, .plane { position:fixed; z-index:12; pointer-events:none; will-change:transform, opacity; }
.strip { overflow:hidden; }
.strip .card { position:absolute; left:0; margin:0; box-shadow:none; }
.plane { left:0; top:0; width:120px; height:72px; margin:-36px 0 0 -60px; filter:drop-shadow(0 0 10px rgba(var(--fx),.85)); }
.plane svg { width:100%; height:100%; display:block; }
/* Stardust: a soft glow on the edge with a dusting of grains. Lightning: a faint lavender glow, never red, nothing flashes. */
html[data-effect=stardust] .portal .rays, html[data-effect=stardust] .portal .rift, html[data-effect=lightning] .portal .rays, html[data-effect=lightning] .portal .rift { display:none; }
html[data-effect=stardust] .portal::before { background:radial-gradient(circle at 30% 40%, rgba(var(--fx2),.7) 0 1px, transparent 1.5px) 0 0/13px 17px, radial-gradient(ellipse 45% 40% at 0 50%, rgba(var(--fx),.45), rgba(var(--fx3),.12) 55%, rgba(var(--fx3),0)); -webkit-mask:radial-gradient(ellipse 40% 45% at 0 50%, #000, transparent); mask:radial-gradient(ellipse 40% 45% at 0 50%, #000, transparent); }
html[data-effect=stardust] .portal::after { display:none; }
html[data-effect=lightning] .portal::before { background:radial-gradient(ellipse 70% 55% at 0 50%, rgba(214,206,255,.5), rgba(170,190,255,.2) 50%, rgba(170,190,255,0)); }
html[data-effect=lightning] .portal::after { display:none; }
html[data-effect=lightning] .portal.flash, html[data-effect=stardust] .portal.flash { animation:portalFade .2s both; }
/* Liquid: a bulge of water on the edge; the card turns into a drop. */
html[data-effect=liquid] .portal::before { background:radial-gradient(ellipse 55% 40% at 0 50%, rgba(var(--fx2),.95), rgba(var(--fx),.85) 45%, rgba(var(--fx3),.5) 62%, rgba(var(--fx3),0) 74%); }
html[data-effect=liquid] .portal::after { display:none; }
html[data-effect=liquid] .card .flare { background:radial-gradient(circle at 32% 28%, rgba(255,255,255,.75), rgba(var(--fx),.55) 30%, rgba(var(--fx3),.45)); }
/* Wormhole: a ring of light half out of the edge, spinning. */
html[data-effect=wormhole] .portal::before { background:radial-gradient(circle at 0 50%, rgba(12,10,24,.9) 0, rgba(12,10,24,.9) 9vw, rgba(var(--fx),.55) 16vw, rgba(var(--fx3),0) 28vw); }
html[data-effect=wormhole] .portal::after { display:none; }
html[data-effect=wormhole] .portal .ring { display:block; left:-32vw; top:50%; width:64vw; height:64vw; margin-top:-32vw; border-radius:50%; background:conic-gradient(#fff, rgb(var(--fx)), rgba(var(--fx3),0) 30%, rgb(var(--fx3)), rgb(var(--fx2)) 60%, rgba(var(--fx),0) 80%, #fff); -webkit-mask:radial-gradient(circle, transparent 52%, #000 55%, #000 68%, transparent 71%); mask:radial-gradient(circle, transparent 52%, #000 55%, #000 68%, transparent 71%); }
/* Two dim inset rims, at .72 and .46 of the ring: the tunnel. Static paint; the drag turns them. */
html[data-effect=wormhole] .portal .rays { left:-32vw; top:50%; width:64vw; height:64vw; margin-top:-32vw; border-radius:50%; background:radial-gradient(circle closest-side, transparent 41%, rgba(var(--fx2),.6) 43%, rgba(var(--fx),.35) 45.5%, transparent 47.5%), radial-gradient(circle closest-side, transparent 25.5%, rgba(var(--fx),.6) 27.5%, rgba(var(--fx3),.25) 29.5%, transparent 31.5%); }
html[data-effect=wormhole] .portal.flash { animation:ringFlash .08s cubic-bezier(.16,1,.3,1); }
html[data-effect=wormhole] .card .flare { background:radial-gradient(circle at 0 50%, rgba(var(--fx2),.95), rgba(var(--fx),.5) 50%, transparent 80%); }
@keyframes ringFlash { 0% { opacity:.7; transform:scale(1); } 40% { opacity:.95; transform:scale(1.12); } 100% { opacity:0; transform:scale(1.18); } }
/* Beam: scanlines and a cyan line; the card leaves in strips. */
html[data-effect=beam] .portal::before { background:repeating-linear-gradient(0deg, rgba(var(--fx),.75) 0 1px, transparent 1px 6px); -webkit-mask:linear-gradient(90deg, #000, transparent 85%); mask:linear-gradient(90deg, #000, transparent 85%); }
html[data-effect=beam] .portal::after { width:3px; background:linear-gradient(transparent, #fff 20%, #fff 80%, transparent); box-shadow:0 0 24px 7px rgba(var(--fx),.95), 0 0 60px 16px rgba(var(--fx3),.4); }
html[data-effect=beam] .card .flare { background:repeating-linear-gradient(0deg, rgba(var(--fx2),.65) 0 2px, transparent 2px 7px), linear-gradient(90deg, rgba(var(--fx),.5), transparent 70%); }
/* Paper plane: a soft breeze on the edge; the card folds. */
html[data-effect=plane] .portal::before { background:radial-gradient(ellipse 100% 60% at 0 50%, rgba(var(--fx2),.55), rgba(var(--fx),.3) 45%, rgba(var(--fx3),0)); }
html[data-effect=plane] .portal::after { display:none; }
html[data-effect=plane] .portal .wind { display:block; left:3vw; top:36%; width:20vw; height:28%; background:repeating-linear-gradient(0deg, transparent 0 26px, rgba(var(--fx2),.75) 26px 28px); -webkit-mask:linear-gradient(90deg, transparent, #000 30%, #000 55%, transparent); mask:linear-gradient(90deg, transparent, #000 30%, #000 55%, transparent); }
html[data-effect=plane] .card .flare { background:linear-gradient(45deg, transparent 49.4%, rgba(255,255,255,.7) 50%, transparent 50.6%), linear-gradient(135deg, transparent 49.4%, rgba(255,255,255,.7) 50%, transparent 50.6%), linear-gradient(90deg, rgba(var(--fx2),.4), rgba(var(--fx),.12)); }
/* Static-painted hero geometry; motion stays on its compositor wrapper. */
.portal .hero-light { display:block; position:absolute; width:720px; height:720px; left:-360px; top:50%; margin-top:-360px; overflow:visible; will-change:transform; }
.hero-light .signature { display:none; }
.hero-light .k-core { stroke:#fff; } .hero-light .k-fx { stroke:rgb(var(--fx)); } .hero-light .k-fx2 { stroke:rgb(var(--fx2)); } .hero-light .k-fx3 { stroke:rgb(var(--fx3)); }
.hero-light .f-paper { fill:#f7f8ff; } .hero-light .f-shade { fill:rgb(var(--fx3)); fill-opacity:.55; }
.hero-light .s-core { stop-color:rgb(var(--fx2)); } .hero-light .s-fx { stop-color:rgb(var(--fx)); } .hero-light .s-fx3 { stop-color:rgb(var(--fx3)); }
html[data-effect=portal] .hero-light .portal-signature,
html[data-effect=liquid] .hero-light .liquid-signature,
html[data-effect=wormhole] .hero-light .wormhole-signature,
html[data-effect=beam] .hero-light .beam-signature,
html[data-effect=plane] .hero-light .plane-signature { display:block; }
html[data-effect=wormhole] .portal .ring, html[data-effect=wormhole] .portal .rays { display:none; }
@media (prefers-reduced-motion:reduce) { .portal .hero-light { display:none; } }
@media (prefers-reduced-motion: reduce) {
  .portal { transform:none !important; transition:opacity .3s; }
  .veil, .portal .rays { display:none !important; }
  .portal.flash { animation:portalFade .16s cubic-bezier(.22,0,.58,1) !important; }
  .portal .ring { animation:none !important; }
}
section.text { margin-top:8px; background:var(--card); border-radius:18px; padding:12px; }
textarea { width:100%; min-height:88px; resize:vertical; border:1px solid var(--line); background:#111118; color:var(--text); border-radius:12px; padding:10px; font:16px/1.4 -apple-system, system-ui, sans-serif; }
.row { display:flex; gap:10px; margin-top:10px; align-items:center; }
.btn { flex:none; height:44px; padding:0 18px; border-radius:12px; border:0; background:#2c2c38; color:var(--text); font-size:16px; font-weight:600; }
.btn.primary { background:var(--accent); color:#fff; }
.status { color:var(--dim); font-size:13px; flex:1; }
.notice { display:none; margin:0 0 14px; padding:10px 12px; border-radius:12px; background:var(--card); color:var(--dim); font-size:14px; }
.notice.on { display:block; }
.notice.bad { color:var(--bad); }
.btn[hidden] { display:none; }
.shortcuts { margin:28px 0 24px; }
.shortcuts[hidden] { display:none; }
.shortcuts h2 { font-size:15px; color:var(--dim); font-weight:600; margin:0 0 8px; }
.schint { font-size:12px; color:var(--dim); }
a.btn { display:inline-flex; align-items:center; text-decoration:none; }
.sharehint { color:var(--dim); font-size:13px; margin:8px 0 0; }
.keep { color:var(--dim); font-size:13px; margin:-8px 0 14px; }
.shrink { display:flex; align-items:center; gap:10px; margin:10px 2px 0; color:var(--text); font-size:15px; }
.shrink input { width:22px; height:22px; margin:0; accent-color:var(--accent); }
.shrink small { color:var(--dim); font-size:13px; margin-left:auto; text-align:right; }
.card .saved { position:absolute; top:8px; right:8px; padding:3px 8px; border-radius:11px; background:rgba(0,0,0,.6); color:var(--ok); font-size:12px; font-weight:600; z-index:1; }
.keep[hidden] { display:none; }
.card.selected { box-shadow:0 0 0 3px var(--accent), 0 6px 18px rgba(0,0,0,.35); }
.card.selected::after { content:"\2713"; position:absolute; top:8px; right:8px; width:26px; height:26px; border-radius:13px; background:var(--accent); color:#fff; font-size:15px; font-weight:700; display:flex; align-items:center; justify-content:center; }
.card.queued .badge { display:flex; color:var(--dim); }
.card .count { position:absolute; top:8px; left:8px; min-width:26px; height:26px; padding:0 8px; box-sizing:border-box; border-radius:13px; background:var(--accent); color:#fff; font-size:15px; font-weight:700; display:none; align-items:center; justify-content:center; z-index:1; }
.card.stacktop .count { display:flex; }
.card.stacked::after { display:none; }
.card.stacked { box-shadow:0 6px 18px rgba(0,0,0,.35); }
.card.gathering { transition:transform .15s cubic-bezier(.2,.8,.2,1); }
.inbox { margin:0 0 16px; }
.inbox[hidden] { display:none; }
.inbox h2 { font-size:15px; color:var(--dim); font-weight:600; margin:0 0 8px; }
.in { background:var(--card); border-radius:18px; padding:12px; margin-bottom:10px; }
.in img { display:block; max-width:100%; max-height:240px; border-radius:12px; margin:0 auto 4px; -webkit-touch-callout:default; }
.in .row { margin-top:6px; }
.in .status { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.in.arrive { animation:inArrive .5s cubic-bezier(.2,.8,.2,1) both; }
@keyframes inArrive { 0% { transform:translateX(-105%) scale(.92); opacity:0; box-shadow:-18px 0 36px 6px rgba(var(--fx),.9); } 60% { opacity:1; box-shadow:-6px 0 26px 2px rgba(var(--fx),.55); } 100% { transform:none; box-shadow:0 0 0 0 rgba(var(--fx),0); } }
@media (prefers-reduced-motion: reduce) { .in.arrive { animation:portalFade .16s reverse both; } }
.in .hint { color:var(--dim); font-size:12px; margin-top:6px; }
.in .clip { white-space:pre-wrap; word-break:break-word; max-height:160px; overflow:auto; font-size:15px; -webkit-user-select:text; user-select:text; }
a.btn { display:inline-flex; align-items:center; text-decoration:none; }
.recent { margin:16px 0 8px; }
.recent[hidden] { display:none; }
.recent h2 { font-size:15px; color:var(--dim); font-weight:600; margin:0 0 8px; }
.rec { display:flex; align-items:center; gap:10px; padding:8px 10px; background:var(--card); border-radius:14px; margin-bottom:6px; color:var(--text); text-decoration:none; }
.rthumb { flex:none; width:40px; height:40px; border-radius:8px; background:#2c2c38; color:var(--dim); font-size:10px; font-weight:700; display:flex; align-items:center; justify-content:center; overflow:hidden; }
.rthumb img { width:100%; height:100%; object-fit:cover; }
.rtext { flex:1; min-width:0; }
.rname { font-size:15px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.rmeta { font-size:12px; color:var(--dim); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.btn.small { height:34px; padding:0 12px; font-size:14px; border-radius:10px; }
/* The tour: three steps on first visit, again from "?". Its own tokens, so it follows the phone's light or dark. */
header { align-items:center; }
.help { flex:none; width:32px; height:32px; border-radius:16px; border:0; background:#2c2c38; color:var(--text); font-size:17px; font-weight:700; }
.tour { --t-bg:#1c1c24; --t-text:#f2f2f5; --t-dim:#9a9aa6; --t-stage:#101016; --t-line:#34343f; --t-btn:#2c2c38; position:fixed; inset:0; z-index:20; display:flex; align-items:flex-end; justify-content:center; padding:16px 16px calc(env(safe-area-inset-bottom) + 16px); background:rgba(0,0,0,.5); animation:tourIn .2s ease-out; }
.tour[hidden] { display:none; }
@media (prefers-color-scheme: light) { .tour { --t-bg:#ffffff; --t-text:#15151a; --t-dim:#6b6b76; --t-stage:#eef0f5; --t-line:#d4d6de; --t-btn:#e6e7ec; background:rgba(0,0,0,.3); } }
.tour-sheet { width:100%; max-width:420px; background:var(--t-bg); color:var(--t-text); border-radius:24px; padding:16px; box-shadow:0 12px 40px rgba(0,0,0,.4); }
.tour-stage { position:relative; height:140px; border-radius:16px; background:var(--t-stage); overflow:hidden; }
.tour-step { position:absolute; inset:0; display:none; }
.tour[data-step="0"] .s0, .tour[data-step="1"] .s1, .tour[data-step="2"] .s2 { display:block; }
.tour h2 { font-size:20px; margin:14px 0 4px; letter-spacing:-0.01em; }
.tour p { margin:0; color:var(--t-dim); font-size:14px; min-height:20px; }
.tour-dots { display:flex; gap:6px; justify-content:center; margin:14px 0; }
.tour-dots i { width:7px; height:7px; border-radius:4px; background:var(--t-line); transition:width .2s, background .2s; }
.tour[data-step="0"] .tour-dots i:nth-child(1), .tour[data-step="1"] .tour-dots i:nth-child(2), .tour[data-step="2"] .tour-dots i:nth-child(3) { width:20px; background:var(--accent); }
.tour-row { display:flex; gap:10px; }
.tour-row .btn { height:48px; }
.tour-row .tour-back { background:var(--t-btn); color:var(--t-text); }
.tour-row .tour-skip { background:transparent; color:var(--t-dim); padding:0 8px; }
.tour-row .tour-next { flex:1; }
.tour .hand { position:absolute; width:34px; height:44px; filter:drop-shadow(0 2px 3px rgba(0,0,0,.35)); }
.tour .mini { position:absolute; border-radius:10px; background:linear-gradient(135deg, rgb(var(--fx)), rgb(var(--fx3))); box-shadow:0 4px 12px rgba(0,0,0,.3); }
/* Step 1: tap Pick, three cards appear. */
.s0 .tpick { position:absolute; left:50%; top:18px; width:150px; margin-left:-75px; height:36px; border-radius:12px; background:var(--accent); color:#fff; font-size:15px; font-weight:600; display:flex; align-items:center; justify-content:center; animation:tPress 2.6s infinite; }
.s0 .mini { top:72px; width:48px; height:48px; animation:tPop 2.6s infinite both; }
.s0 .m1 { left:calc(50% - 82px); } .s0 .m2 { left:calc(50% - 24px); animation-delay:.12s; } .s0 .m3 { left:calc(50% + 34px); animation-delay:.24s; }
.s0 .hand { left:calc(50% + 30px); top:36px; animation:tTap 2.6s infinite; }
/* Step 2: the card and the finger leave by the left edge, which lights up. */
.s1 .edge { position:absolute; left:0; top:10px; bottom:10px; width:4px; border-radius:2px; background:rgb(var(--fx2)); box-shadow:0 0 14px 4px rgb(var(--fx)); animation:tEdge 2.2s infinite; }
.s1 .mini { left:calc(50% - 32px); top:38px; width:64px; height:64px; animation:tFlick 2.2s infinite; }
.s1 .hand { left:calc(50% - 4px); top:62px; animation:tFlickHand 2.2s infinite; }
/* Step 3: the card lands on the Mac from its right edge. */
.s2 .mac { position:absolute; left:50%; top:16px; width:170px; height:100px; margin-left:-85px; border-radius:8px; border:3px solid var(--t-line); background:var(--t-bg); overflow:hidden; }
.s2 .base { position:absolute; left:50%; top:117px; width:200px; height:6px; margin-left:-100px; border-radius:0 0 6px 6px; background:var(--t-line); }
.s2 .medge { position:absolute; right:0; top:6px; bottom:6px; width:3px; border-radius:2px; background:rgb(var(--fx2)); box-shadow:0 0 10px 3px rgb(var(--fx)); animation:tEdge 2.4s infinite reverse; }
.s2 .mini { left:56px; top:22px; width:46px; height:46px; animation:tLand 2.4s infinite both; }
@keyframes tourIn { from { opacity:0; } }
@keyframes tPress { 0%, 22%, 40%, 100% { transform:none; } 30% { transform:scale(.94); } }
@keyframes tTap { 0% { transform:translate(30px, 30px); opacity:0; } 18% { transform:none; opacity:1; } 30% { transform:scale(.9); } 42% { transform:none; opacity:1; } 60%, 100% { transform:translate(30px, 40px); opacity:0; } }
@keyframes tPop { 0%, 34% { transform:scale(.4); opacity:0; } 46% { transform:scale(1.08); opacity:1; } 54%, 88% { transform:none; opacity:1; } 100% { opacity:0; } }
@keyframes tFlick { 0%, 15% { transform:none; opacity:1; } 55% { transform:translateX(-160px) rotate(-8deg); opacity:1; } 62%, 80% { transform:translateX(-160px); opacity:0; } 100% { transform:none; opacity:0; } }
@keyframes tFlickHand { 0% { transform:translate(10px, 10px); opacity:0; } 12% { transform:none; opacity:1; } 50% { transform:translateX(-120px); opacity:1; } 62%, 100% { transform:translateX(-140px); opacity:0; } }
@keyframes tEdge { 0%, 20% { opacity:.35; } 50% { opacity:1; } 80%, 100% { opacity:.35; } }
@keyframes tLand { 0%, 10% { transform:translateX(140px); opacity:0; } 40% { transform:scale(1.12); opacity:1; } 52%, 86% { transform:none; opacity:1; } 100% { opacity:0; } }
@media (prefers-reduced-motion: reduce) {
  .tour, .tour * { animation:none !important; }
  .s0 .hand { opacity:1; }
  .s1 .mini { transform:translateX(-40px); } .s1 .hand { transform:translateX(-30px); }
}
</style>
</head>
<body>
<div class="veil" id="veil"></div>
<div class="portal" id="portal"><svg class="hero-light" viewBox="-360 -360 720 720" aria-hidden="true"><defs>
<radialGradient id="edge-blue"><stop class="s-core" stop-opacity=".8"/><stop class="s-fx" offset=".35" stop-opacity=".6"/><stop class="s-fx3" offset="1" stop-opacity="0"/></radialGradient>
<linearGradient id="water"><stop class="s-core" stop-opacity=".85"/><stop class="s-fx" offset="1" stop-opacity=".25"/></linearGradient>
<g id="rims" fill="none"><ellipse rx="190" ry="310"/><ellipse rx="130" ry="225"/><ellipse rx="75" ry="140"/></g>
<ellipse id="wave" rx="260" ry="190" fill="none"/>
<path id="crown" d="M0 -230 Q180 -160 150 -80 Q300 0 150 80 Q180 160 0 230 M20 -170 Q240 -145 270 0 Q240 145 20 170" fill="none"/>
<path id="trail" d="M0 -50 Q120 -55 250 -190 M0 50 Q120 55 250 190" fill="none"/>
</defs>
<ellipse rx="250" ry="350" fill="url(#edge-blue)"/>
<g class="signature portal-signature"><use href="#wave" class="k-fx3" stroke-width="22" opacity=".35"/><use href="#wave" class="k-fx" stroke-width="8" opacity=".85"/><use href="#wave" class="k-core" stroke-width="3"/><path d="M0 -330V330" class="k-fx" stroke-width="14" opacity=".6"/><path d="M0 -330V330" class="k-core" stroke-width="5"/></g>
<g class="signature wormhole-signature"><use href="#rims" class="k-fx3" stroke-width="26" opacity=".4"/><use href="#rims" class="k-fx" stroke-width="10"/><use href="#rims" class="k-core" stroke-width="4"/></g>
<g class="signature liquid-signature"><use href="#crown" class="k-fx3" stroke-width="22" opacity=".45"/><use href="#crown" class="k-fx" stroke-width="8" opacity=".85"/><use href="#crown" class="k-core" stroke-width="3"/><g fill="url(#water)" class="k-core"><ellipse cx="205" cy="-150" rx="24" ry="7" transform="rotate(-30 205 -150)"/><ellipse cx="220" cy="130" rx="26" ry="8" transform="rotate(35 220 130)"/><ellipse cx="120" cy="-260" rx="9" ry="23"/><ellipse cx="100" cy="250" rx="9" ry="24"/></g></g>
<g class="signature beam-signature" fill="none"><path class="k-fx" d="M0 -150H300 M0 -112H300 M0 -75H300 M0 -37H300 M0 0H300 M0 37H300 M0 75H300 M0 112H300 M0 150H300" stroke-width="7" opacity=".55"/><path class="k-fx2" d="M0 -150H300 M0 -112H300 M0 -75H300 M0 -37H300 M0 0H300 M0 37H300 M0 75H300 M0 112H300 M0 150H300" stroke-width="2.5"/><path d="M3 -240V240" class="k-fx" stroke-width="14" opacity=".6"/><path d="M3 -240V240" class="k-core" stroke-width="5"/></g>
<g class="signature plane-signature"><use href="#trail" class="k-fx3" stroke-width="20" opacity=".4"/><use href="#trail" class="k-fx" stroke-width="7" opacity=".85"/><use href="#trail" class="k-core" stroke-width="2.5"/><path d="M0 0L230 -170L145 -20L280 0L145 20L230 170Z" class="f-paper"/><path d="M0 0L145 -20L230 -170L100 -35Z M0 0L145 20L230 170L100 35Z" class="f-shade"/></g>
</svg><div class="fx rays"></div><div class="fx rift"></div><div class="fx ring"></div><div class="fx wind"></div></div>
<canvas class="sparks" id="sparks"></canvas>
<header><h1>Drop Portal</h1><button class="help" id="help" aria-label="How it works">?</button></header>
<div class="tour" id="tour" data-step="0" role="dialog" aria-modal="true" aria-labelledby="tourTitle" hidden><div class="tour-sheet">
<div class="tour-stage" aria-hidden="true">
<div class="tour-step s0"><div class="tpick">Pick</div><i class="mini m1"></i><i class="mini m2"></i><i class="mini m3"></i><svg class="hand" viewBox="0 0 34 44" aria-hidden="true"><path d="M11 4.5a3.5 3.5 0 0 1 7 0V19l1.4-.6a3.3 3.3 0 0 1 4.3 1.8l.6-.2a3.3 3.3 0 0 1 4.2 2.2l.5-.1a3 3 0 0 1 3.5 3V32c0 6.6-5 11-11 11h-3c-4 0-6.6-2-8.4-5.6L3.4 28a3 3 0 0 1 5-3.3L11 28z" fill="#fff" stroke="#15151a" stroke-width="1.6" stroke-linejoin="round"/></svg></div>
<div class="tour-step s1"><i class="edge"></i><i class="mini"></i><svg class="hand" viewBox="0 0 34 44" aria-hidden="true"><path d="M11 4.5a3.5 3.5 0 0 1 7 0V19l1.4-.6a3.3 3.3 0 0 1 4.3 1.8l.6-.2a3.3 3.3 0 0 1 4.2 2.2l.5-.1a3 3 0 0 1 3.5 3V32c0 6.6-5 11-11 11h-3c-4 0-6.6-2-8.4-5.6L3.4 28a3 3 0 0 1 5-3.3L11 28z" fill="#fff" stroke="#15151a" stroke-width="1.6" stroke-linejoin="round"/></svg></div>
<div class="tour-step s2"><div class="mac"><i class="mini"></i><i class="medge"></i></div><i class="base"></i></div>
</div>
<h2 id="tourTitle">Pick photos or files</h2><p id="tourText"></p>
<div class="tour-dots" aria-hidden="true"><i></i><i></i><i></i></div>
<div class="tour-row"><button class="btn tour-skip" id="tourSkip">Skip</button><button class="btn tour-back" id="tourBack" hidden>Back</button><button class="btn primary tour-next" id="tourNext">Next</button></div>
</div></div>
<div class="notice" id="notice"></div>
<p class="keep" id="keep" hidden>Keep this page open while sending.</p>
<section class="inbox" id="inbox" hidden><h2>From your Mac</h2><div id="inboxList"></div></section>
<label class="pick">Pick<input id="file" type="file" multiple></label>
<label class="shrink"><input type="checkbox" id="shrink">Smaller files<small id="shrinkHint" hidden>Photos up to 2560 px. Videos are sent as they are.</small></label>
<div class="grid" id="grid"></div>
<div class="empty" id="empty">Nothing picked yet.</div>
<section class="text">
  <textarea id="text" placeholder="Paste text here" autocomplete="off"></textarea>
  <div class="row"><span class="status" id="textStatus"></span><button class="btn primary" id="sendText">Send</button></div>
</section>
<section class="recent" id="recent" hidden><h2>Recent</h2><div id="recentList"></div></section>
<section class="shortcuts" id="shortcuts" hidden><h2>iPhone Shortcuts</h2><!--shortcut-rows--><p class="sharehint">Tap Add, then Add Shortcut. After Reset pairing on the Mac, add them again.</p></section>
<!--webgl-->
<script>
(function () {
  "use strict";
  var token = new URLSearchParams(location.search).get("t") || "";
  var notice = document.getElementById("notice");
  function say(message, bad) { notice.textContent = message || ""; notice.classList.toggle("on", !!message); notice.classList.toggle("bad", !!bad); }
  if (!token) say("Scan the QR code in Drop Portal's settings on your Mac.", true);
  // The shortcuts are iOS only: other phones never see them.
  var appleTouch = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  if (token && appleTouch) {
    // Each is signed for this Mac; Safari downloads it and Shortcuts offers to add it.
    Array.prototype.forEach.call(document.querySelectorAll("a[data-shortcut]"), function (a) {
      a.href = a.getAttribute("data-shortcut") + "?t=" + encodeURIComponent(token);
    });
    document.getElementById("shortcuts").hidden = false;
  }

  // The tour: three steps on the first visit (once per phone under TOUR_KEY), again from "?". Skip, Done, Escape or a tap outside closes it for good.
  var TOUR_KEY = "dropportal.tour.v2";
  var TOUR = [
    ["Pick photos or files", "Tap Pick and choose what to send."],
    ["Flick them off the left edge", "Tap cards first to flick several at once."],
    ["They land on your Mac", "To send from Mac, drag to the right edge of your Mac screen."]
  ];
  var tour = document.getElementById("tour"), tourStep = 0;
  var tourNext = document.getElementById("tourNext"), tourBack = document.getElementById("tourBack");
  function showStep(i) {
    tourStep = i;
    tour.setAttribute("data-step", String(i));
    document.getElementById("tourTitle").textContent = TOUR[i][0];
    document.getElementById("tourText").textContent = TOUR[i][1];
    tourBack.hidden = i === 0;
    document.getElementById("tourSkip").hidden = i === TOUR.length - 1;
    tourNext.textContent = i === TOUR.length - 1 ? "Done" : "Next";
  }
  function openTour() { showStep(0); tour.hidden = false; tourNext.focus(); }
  function closeTour() {
    tour.hidden = true;
    try { localStorage.setItem(TOUR_KEY, "1"); } catch (_) {}
  }
  tourNext.addEventListener("click", function () { if (tourStep < TOUR.length - 1) showStep(tourStep + 1); else closeTour(); });
  tourBack.addEventListener("click", function () { showStep(Math.max(0, tourStep - 1)); });
  document.getElementById("tourSkip").addEventListener("click", closeTour);
  tour.addEventListener("click", function (e) { if (e.target === tour) closeTour(); });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !tour.hidden) closeTour(); });
  document.getElementById("help").addEventListener("click", openTour);
  // A new key: every phone sees this tour once, even one that dismissed the old one-line hint
  // (`dropportal.tip`) or saw the first tour (`dropportal.tour`).
  var tourSeen = false;
  try { tourSeen = localStorage.getItem(TOUR_KEY) === "1"; } catch (_) {}
  if (token && !tourSeen) openTour();

  var UNREACHABLE = "Mac not reachable - same Wi-Fi? Tap to retry.";
  // No upload progress for this long: the Mac is gone, so give up and let a tap retry.
  var STALL_TIMEOUT = 20000;
  var grid = document.getElementById("grid"), empty = document.getElementById("empty");

  function el(tag, cls) { var e = document.createElement(tag); if (cls) e.className = cls; return e; }
  function updateEmpty() { empty.style.display = grid.children.length ? "none" : "block"; }

  document.getElementById("file").addEventListener("change", function (e) {
    Array.prototype.forEach.call(e.target.files, addCard);
    e.target.value = "";
    updateEmpty();
  });

  function addCard(file) {
    var card = el("div", "card");
    var type = file.type || "";
    var url = null;
    if (type.indexOf("image/") === 0) {
      url = URL.createObjectURL(file);
      var img = el("img"); img.alt = ""; card.appendChild(img);
      img.addEventListener("load", function () { makeThumb(card, img, img.naturalWidth, img.naturalHeight); });
      img.src = url;
    } else if (type.indexOf("video/") === 0) {
      url = URL.createObjectURL(file);
      var v = el("video"); v.muted = true; v.playsInline = true; v.preload = "metadata"; card.appendChild(v);
      var grab = function () { if (!card._thumb) makeThumb(card, v, v.videoWidth, v.videoHeight); };
      v.addEventListener("loadeddata", grab); v.addEventListener("seeked", grab);
      v.src = url + "#t=0.1";
    } else {
      var d = el("div", "doc"); var ext = (file.name.split(".").pop() || "FILE").slice(0, 5).toUpperCase();
      d.textContent = ext; card.appendChild(d);
    }
    var name = el("div", "name"); name.textContent = file.name; card.appendChild(name);
    var bar = el("div", "bar"); var fill = el("i"); bar.appendChild(fill); card.appendChild(bar);
    var badge = el("div", "badge"); card.appendChild(badge);
    var flare = el("div", "flare"); card.appendChild(flare);
    var count = el("div", "count"); card.appendChild(count);
    card._file = file; card._url = url; card._fill = fill; card._badge = badge; card._flare = flare; card._count = count;
    grid.appendChild(card);
    makeDraggable(card);
  }

  // A small JPEG of the card (about 160 px, under 20 KB) for the Mac's preview,
  // made right after Pick so a touch can send it at once.
  var THUMB_SIDE = 160, THUMB_CHARS = 27000, THUMB_MAX_CHARS = 60000;
  function makeThumb(card, source, w, h) {
    if (!w || !h || card._thumb) return;
    var scale = Math.min(1, THUMB_SIDE / Math.max(w, h));
    var c = el("canvas"); c.width = Math.max(1, Math.round(w * scale)); c.height = Math.max(1, Math.round(h * scale));
    try {
      c.getContext("2d").drawImage(source, 0, 0, c.width, c.height);
      var q = 0.7, data;
      do { data = c.toDataURL("image/jpeg", q); q -= 0.15; } while (data.length > THUMB_CHARS && q > 0.2);
      var b64 = data.slice(data.indexOf(",") + 1);
      if (b64.length <= THUMB_MAX_CHARS) card._thumb = b64;
    } catch (_) {}
  }

  // The peek socket: lets the Mac show the card while it is dragged. Best
  // effort only; when it is down everything works, without the preview.
  var PEEK_PORT = 8788, sock = null, sockRetry = null, sockDelay = 3000, sockPing = null;
  function connect() {
    if (!token || document.hidden || sock || !window.WebSocket) return;
    clearTimeout(sockRetry);
    var s;
    try { s = new WebSocket("ws://" + location.hostname + ":" + PEEK_PORT + "/"); } catch (_) { return; }
    sock = s;
    s.onopen = function () { try { s.send(JSON.stringify({ type: "hello", t: token })); } catch (_) {} };
    // The Mac answers hello with "ready": that is when the retry pause starts over.
    // It carries the crossing effect, again whenever it changes in the Mac's settings.
    s.onmessage = function (e) {
      sockDelay = 3000;
      try {
        var m = JSON.parse(e.data);
        if (m && typeof m.effect === "string") setEffect(m.effect);
        if (m && typeof m.tint === "string") setTint(m.tint);
        if (m && (m.type === "ready" || m.type === "effect")) kinetic = m.kinetic !== false;
        if (m && m.type === "incoming") incoming(m);
        if (m && m.type === "clipboard" && typeof m.text === "string") clipboard(m.text);
      } catch (_) {}
    };
    // An idle page pings every 10 s: the Mac drops silent sockets after 30 s and then shows the phone as gone.
    clearInterval(sockPing);
    sockPing = setInterval(function () { if (sock === s && s.readyState === 1 && !peek) { try { s.send('{"type":"ping"}'); } catch (_) {} } }, 10000);
    s.onclose = s.onerror = function () {
      if (sock !== s) return;
      sock = null; clearInterval(sockPing);
      // 3 s, then longer each time up to 30 s, so a Mac that is off costs the phone almost nothing.
      clearTimeout(sockRetry); sockRetry = setTimeout(connect, sockDelay);
      sockDelay = Math.min(30000, sockDelay * 2);
    };
  }
  function peekSend(msg) {
    if (!sock || sock.readyState !== 1 || sock.bufferedAmount > 262144) return;
    try { sock.send(JSON.stringify(msg)); } catch (_) {}
  }
  // One peek at a time: {id, type, progress}. Moves go out once per frame,
  // the latest value only, plus a beat each second so the Mac knows it is alive.
  var peek = null, peekFrame = 0, peekBeat = null, peekCount = 0;
  function peekKind(type) { return type.indexOf("image/") === 0 ? "image" : type.indexOf("video/") === 0 ? "video" : "file"; }
  function peekFlush() { if (peekFrame) { cancelAnimationFrame(peekFrame); peekFrame = 0; } }
  function peekStart(card, count) {
    peekEnd(null);
    // Rainbow: this crossing's hue, taken when the Mac takes it (at peek-start).
    if (tint === "rainbow") applyTint();
    var f = card._file;
    peek = { id: "p" + Date.now().toString(36) + "-" + (++peekCount), type: "peek-move", progress: 0 };
    var start = { type: "peek-start", id: peek.id, name: f.name || "file", kind: peekKind(f.type || ""), size: f.size, thumb: card._thumb || "", count: count || 1 };
    // A courier (WebCourierEffect.swift): the seed both screens play, and the short version.
    var courier = window.DPCourier && DPCourier.begin(effect, count || 1);
    if (courier) { start.seed = courier.seed; start.short = courier.short; }
    peekSend(start);
    peekBeat = setInterval(function () { if (peek) peekSend({ type: peek.type, id: peek.id, progress: peek.progress, y: peek.y }); }, 1000);
  }
  // `y`: the card's middle, 0 top to 1 bottom, so the Mac card comes out at the same height.
  function peekUpdate(id, type, progress, y) {
    if (!peek || peek.id !== id) return;
    peek.type = type; peek.progress = progress;
    if (y !== undefined) peek.y = y;
    if (peekFrame) return;
    peekFrame = requestAnimationFrame(function () {
      peekFrame = 0;
      if (peek) peekSend({ type: peek.type, id: peek.id, progress: peek.progress, y: peek.y });
    });
  }
  // `r`: how the finger let go (px/s, y down; exit height 0 to 1; degrees), so the Mac card carries the throw on.
  function peekCommit(r) {
    if (!peek) return null;
    peekFlush();
    r = r || {};
    peekSend({ type: "peek-commit", id: peek.id, vx: r.vx, vy: r.vy, exitY: r.exitY, angle: r.angle });
    peek.type = "peek-progress"; peek.progress = 0;
    return peek.id;
  }
  // Ends the peek; `type` "peek-cancel" tells the Mac, null ends it quietly.
  function peekEnd(type, id) {
    if (!peek || (id && peek.id !== id)) return;
    peekFlush();
    if (type) peekSend({ type: type, id: peek.id });
    peek = null; clearInterval(peekBeat); peekBeat = null;
  }
  // A hidden page frees its slot on the Mac; coming back reconnects at once.
  function hidden() {
    peekEnd("peek-cancel");
    if (document.hidden && sock) { var s = sock; sock = null; clearInterval(sockPing); try { s.close(); } catch (_) {} }
  }
  document.addEventListener("visibilitychange", function () { if (document.hidden) hidden(); else connect(); });
  window.addEventListener("pagehide", hidden);

  // The portal: a tall light on the left edge that grows with the drag while
  // the page dims away from it and particles trail the finger; on a send the
  // card pulls back, launches, the screen flashes and particles burst into
  // the edge; a cancel fades it all. Reduce motion keeps the light only.
  // Transform and opacity only, plus the one particle canvas.
  // Tune here (the CSS gain --pg and width --pw sit at the top of the style block).
  // veil: the page dims at most 35% away from the edge (0.62 × 0.56).
  var PORTAL = { veil: 0.56 };
  // The spec's curves: A accelerates into the edge, O opens, F retires.
  var EASE = { A: "cubic-bezier(.4,0,.85,.35)", O: "cubic-bezier(.16,1,.3,1)", F: "cubic-bezier(.22,0,.58,1)" };
  var portal = document.getElementById("portal"), sparks = document.getElementById("sparks");
  var heroLight = portal.querySelector(".hero-light");
  var veil = document.getElementById("veil");
  var calmQuery = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  function calm() { return !!(calmQuery && calmQuery.matches); }
  function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
  // The crossing effect the Mac chose: portal, liquid, wormhole, beam, plane, stardust or lightning.
  var EFFECTS = ["portal", "liquid", "wormhole", "beam", "plane", "stardust", "lightning"];
  var root = document.documentElement, effect = "portal";
  function setEffect(name) {
    effect = EFFECTS.indexOf(name) < 0 ? "portal" : name;
    root.setAttribute("data-effect", effect);
  }
  setEffect(root.getAttribute("data-effect"));
  // The effect's colour: "#RRGGBB" or "rainbow", the same tones as PortalTones on
  // the Mac. Set as three CSS variables once per change (and once per drag for
  // Rainbow, whose hue follows the clock exactly as on the Mac), never per frame.
  var tint = "#2F6BFF", TONES = { glow: [47, 107, 255], core: [221, 230, 255], second: [75, 47, 255] };
  function hsvOf(c) {
    var r = c[0] / 255, g = c[1] / 255, b = c[2] / 255, mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn, h = 0;
    if (d > 0) { h = mx === r ? (g - b) / d : mx === g ? 2 + (b - r) / d : 4 + (r - g) / d; h /= 6; if (h < 0) h += 1; }
    return [h, mx === 0 ? 0 : d / mx, mx];
  }
  function rgbOf(h, s, v) {
    h = (h - Math.floor(h)) * 6; var i = Math.floor(h) % 6, f = h - Math.floor(h), p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
    var c = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i];
    return [Math.round(c[0] * 255), Math.round(c[1] * 255), Math.round(c[2] * 255)];
  }
  function rainbowHue() { return (Math.floor(Date.now() / 1500) % 12) / 12; }
  function applyTint() {
    var rainbow = tint === "rainbow", base;
    if (rainbow) base = rgbOf(rainbowHue(), 1, 1);
    else { var n = parseInt(tint.slice(1), 16); base = [n >> 16 & 255, n >> 8 & 255, n & 255]; }
    var hsv = hsvOf(base), sat = hsv[1] < 0.12 ? hsv[1] : Math.max(hsv[1], 0.82), val = Math.max(hsv[2], 0.92);
    var glow = rgbOf(hsv[0], sat, val), second = rgbOf(hsv[0] + (rainbow ? 1 / 3 : 0.075), sat, val);
    var core = glow.map(function (v) { return Math.round(v + (255 - v) * 0.82); });
    TONES = { glow: glow, core: core, second: second };
    root.style.setProperty("--fx", glow.join(","));
    root.style.setProperty("--fx2", core.join(","));
    root.style.setProperty("--fx3", second.join(","));
  }
  function setTint(value) {
    var v = String(value || "");
    tint = /^rainbow$/i.test(v) ? "rainbow" : /^#?[0-9a-f]{6}$/i.test(v) ? "#" + v.replace("#", "").toUpperCase() : "#2F6BFF";
    root.setAttribute("data-tint", tint);
    applyTint();
  }
  setTint(root.getAttribute("data-tint"));
  function glow(p) {
    portal.classList.remove("flash"); portal.classList.add("live");
    portal.style.opacity = Math.pow(p, 0.6).toFixed(3);
    var g = (0.35 + 0.65 * p).toFixed(3);
    // Wormhole: the half-ring grows and turns exactly -70° × p; nothing spins on its own.
    portal.style.transform = calm() ? "" : effect === "wormhole" ? "scale(" + g + ") rotate(" + (-70 * p).toFixed(1) + "deg)" : "scaleX(" + g + ")";
    veil.classList.add("live"); veil.style.opacity = calm() ? "0" : (PORTAL.veil * Math.min(1, p * 1.4)).toFixed(3);
    heroLight.style.transform = calm() ? "" : build(p);
  }
  // The effect's signature builds with p, transform only: Portal's lens grows, Wormhole's rims open
  // from edge-on, Liquid's crown bulges out, Beam's lines stream out of the edge, the plane unfolds.
  function build(p) {
    var f = function (a, b) { return (a + (b - a) * p).toFixed(3); };
    if (effect === "wormhole") return "scaleX(" + f(0.2, 1) + ")";
    if (effect === "liquid") return "scale(" + f(0.3, 1.1) + "," + f(0.8, 1) + ")";
    if (effect === "beam") return "translateX(" + f(-160, 0) + "px) scaleX(" + f(0.4, 1) + ")";
    if (effect === "plane") return "scale(" + f(0.6, 1) + "," + f(0.12, 1) + ")";
    return "scale(" + f(0.4, 1) + ")";
  }
  function glowOff() {
    if (window.DropPortalGL) DropPortalGL.off();
    if (window.DPCourier) DPCourier.off();
    heroLight.style.transform = "";
    portal.classList.remove("live"); portal.style.opacity = "0"; portal.style.transform = "";
    veil.classList.remove("live"); veil.style.opacity = "0";
  }
  function glowFlash() {
    glowOff(); portal.classList.remove("flash");
    void portal.offsetWidth; // restart the animation
    portal.classList.add("flash");
    if (window.DropPortalGL) DropPortalGL.flash();
  }
  portal.addEventListener("animationend", function () { portal.classList.remove("flash"); });

  // Particles: one canvas over the page, drawn only while something lives.
  // Each is {kind, x, y, vx, vy (px/ms), g (px/ms²), drag (/ms), r, life (ms), c "r,g,b"}.
  // Particle colours: the core, the glow and the second tone of the effect's colour.
  function fxColors() { return [TONES.core.join(","), TONES.glow.join(","), TONES.second.join(",")]; }
  var parts = [], fxFrame = 0, fxCtx = null, fxW = 0, fxH = 0;
  function rnd(a, b) { return a + Math.random() * (b - a); }
  function pick(list) { return list[Math.floor(Math.random() * list.length)]; }
  function spawn(q) {
    if (calm()) return;
    q.t0 = performance.now() + (q.delay || 0);
    parts.push(q);
    if (parts.length > 420) parts.splice(0, parts.length - 420);
    if (fxFrame) return;
    var dpr = Math.min(2, window.devicePixelRatio || 1), w = window.innerWidth, h = window.innerHeight;
    if (w !== fxW || h !== fxH || !fxCtx) {
      fxW = w; fxH = h; sparks.width = Math.round(w * dpr); sparks.height = Math.round(h * dpr);
      fxCtx = sparks.getContext("2d"); fxCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    sparks.style.display = "block";
    fxFrame = requestAnimationFrame(fxDraw);
  }
  function fxDraw(now) {
    var ctx = fxCtx, keep = [];
    ctx.clearRect(0, 0, fxW, fxH);
    for (var i = 0; i < parts.length; i++) {
      var q = parts[i], t = now - q.t0;
      if (t < 0) { keep.push(q); continue; }
      var a = 1 - t / q.life;
      if (a <= 0) continue;
      keep.push(q);
      var x, y;
      if (q.pull) {
        // Falls into (px, py) along a spiral.
        var e = Math.pow(t / q.life, 1.6), ang = q.ang + q.swirl * e, rr = q.r0 * (1 - e);
        x = q.px + Math.cos(ang) * rr; y = q.py + Math.sin(ang) * rr;
      } else {
        var k = q.drag ? (1 - Math.exp(-q.drag * t)) / q.drag : t;
        x = q.x + q.vx * k; y = q.y + q.vy * k + 0.5 * (q.g || 0) * t * t;
      }
      fxPaint(ctx, q, x, y, a, t);
    }
    parts = keep;
    if (parts.length) fxFrame = requestAnimationFrame(fxDraw);
    else { fxFrame = 0; ctx.clearRect(0, 0, fxW, fxH); sparks.style.display = "none"; }
  }
  function fxPaint(ctx, q, x, y, a, t) {
    var c = q.c, r = q.r;
    if (q.kind === "drop") {
      ctx.globalCompositeOperation = "source-over";
      ctx.fillStyle = "rgba(" + c + "," + (0.9 * a).toFixed(3) + ")";
      ctx.beginPath(); ctx.arc(x, y, r, 0, 3.1416); ctx.lineTo(x, y - r * 2.6); ctx.closePath(); ctx.fill();
      ctx.fillStyle = "rgba(240,248,255," + (0.8 * a).toFixed(3) + ")";
      ctx.beginPath(); ctx.arc(x - r * 0.3, y - r * 0.1, r * 0.3, 0, 6.2832); ctx.fill();
      return;
    }
    ctx.globalCompositeOperation = "lighter";
    if (q.kind === "ring") {
      // A ripple: an ellipse growing from the edge.
      var gr = r + q.grow * t;
      ctx.strokeStyle = "rgba(" + c + "," + (0.7 * a).toFixed(3) + ")"; ctx.lineWidth = 2 + 4 * a;
      ctx.beginPath(); ctx.ellipse(x, y, gr * 0.55, gr, 0, 0, 6.2832); ctx.stroke();
    } else if (q.kind === "pixel") {
      ctx.fillStyle = "rgba(" + c + "," + a.toFixed(3) + ")";
      ctx.fillRect(x - r, y - r, r * 2, r * 2);
    } else if (q.kind === "bar") {
      // A glitch: a band of the screen jumping sideways, flickering.
      var on = ((t / 45) | 0) % 2 === 0;
      ctx.fillStyle = "rgba(" + c + "," + ((on ? 0.55 : 0.2) * a).toFixed(3) + ")";
      ctx.fillRect(x + (on ? q.j1 : q.j2), y, q.w, r);
    } else if (q.kind === "dash") {
      var len = q.len || 18, ang2 = q.ang || 0;
      ctx.strokeStyle = "rgba(" + c + "," + (0.85 * a).toFixed(3) + ")"; ctx.lineWidth = r; ctx.lineCap = "round";
      ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + Math.cos(ang2) * len, y + Math.sin(ang2) * len); ctx.stroke();
    } else if (q.kind === "star") {
      ctx.strokeStyle = "rgba(255,255,255," + a.toFixed(3) + ")"; ctx.lineWidth = 1.2;
      ctx.beginPath(); ctx.moveTo(x - r * 2.2, y); ctx.lineTo(x + r * 2.2, y); ctx.moveTo(x, y - r * 2.2); ctx.lineTo(x, y + r * 2.2); ctx.stroke();
      ctx.fillStyle = "rgba(" + c + "," + (0.5 * a).toFixed(3) + ")";
      ctx.beginPath(); ctx.arc(x, y, r * 1.6, 0, 6.2832); ctx.fill();
    } else {
      // A mote of light: a halo and a bright core.
      ctx.fillStyle = "rgba(" + c + "," + (a * 0.35).toFixed(3) + ")";
      ctx.beginPath(); ctx.arc(x, y, r * 3, 0, 6.2832); ctx.fill();
      ctx.fillStyle = "rgba(245,250,255," + a.toFixed(3) + ")";
      ctx.beginPath(); ctx.arc(x, y, r, 0, 6.2832); ctx.fill();
    }
  }

  // The impact on the edge, once, when the card has left: Portal light
  // exactly 18 motes, Liquid 16 drops and one ripple; the others none.
  function impactBurst(rect) {
    var c = fxColors(), mid = rect.top + rect.height / 2, i;
    if (effect === "portal") {
      for (i = 0; i < 18; i++) spawn({ kind: "mote", x: 16, y: mid + rnd(-0.4, 0.4) * rect.height, vx: -rnd(0.18, 0.33), vy: rnd(-0.035, 0.035), r: rnd(0.75, 1.5), life: rnd(240, 340), c: Math.random() < 0.7 ? c[0] : c[1] });
    } else if (effect === "liquid") {
      for (i = 0; i < 16; i++) spawn({ kind: "drop", x: 16, y: mid + rnd(-40, 40), vx: -rnd(0.07, 0.18), vy: rnd(-0.11, 0.05), g: 0.00052, r: rnd(1.5, 3), life: rnd(300, 440), c: pick(c.slice(1)) });
      spawn({ kind: "ring", x: 0, y: mid, vx: 0, vy: 0, r: 72, grow: 1.1, life: 80, c: c[2] });
    }
  }

  function makeDraggable(card) {
    var startX = 0, startY = 0, dx = 0, dy = 0, samples = [], active = false, id = null, wasFailed = false, reach = 1;
    var baseLeft = 0, baseWidth = 1, group = [], gathered = false, gatherTimer = null;
    // A selected card gathers the other selected cards into a stack under the
    // finger: on the first move or after a short hold, so a tap that only
    // unselects does not shuffle the grid. They fly in (150 ms) behind it,
    // three at most in sight, and then move with it as one object.
    function gather(instant) {
      clearTimeout(gatherTimer); gatherTimer = null;
      if (gathered || group.length < 2) return;
      gathered = true;
      card._count.textContent = String(group.length); card.classList.add("stacktop");
      var smooth = !instant && !calm();
      group.slice(1).forEach(function (c, i) {
        var L = STACK_LAYERS[Math.min(i, STACK_LAYERS.length - 1)];
        c._gather = "translate(" + (card.offsetLeft - c.offsetLeft) + "px," + (card.offsetTop - c.offsetTop) + "px) ";
        c._layer = " translate(" + L[0] + "px," + L[1] + "px) rotate(" + L[2] + "deg)";
        c._hidden = i >= STACK_LAYERS.length;
        c.classList.remove("back"); c.classList.add("stacked", "drag");
        if (smooth) c.classList.add("gathering");
        c.style.zIndex = String(4 - Math.min(i, 3));
        follow(c);
      });
      if (smooth) setTimeout(function () { group.forEach(function (c) { c.classList.remove("gathering"); }); }, 170);
    }
    // A stacked card takes the top card's transform, opacity, light and shape.
    function follow(c) {
      c.style.transform = c._gather + (card.style.transform || "") + c._layer;
      c.style.opacity = c._hidden ? "0" : card.style.opacity;
      c._flare.style.opacity = card._flare.style.opacity;
      c.classList.toggle("blob", card.classList.contains("blob"));
    }
    function unstack() {
      clearTimeout(gatherTimer); gatherTimer = null;
      card.classList.remove("stacktop");
      if (gathered) group.slice(1).forEach(springBack);
      gathered = false;
    }
    card.addEventListener("pointerdown", function (e) {
      if (card.classList.contains("sending") || card.classList.contains("sent") || card.classList.contains("queued") || card.classList.contains("stacked")) return;
      wasFailed = card.classList.contains("failed");
      if (wasFailed) { card.classList.remove("failed"); }
      active = true; id = e.pointerId; startX = e.clientX; startY = e.clientY; dx = dy = 0;
      samples = [{ x: e.clientX, y: e.clientY, t: e.timeStamp }];
      card.classList.remove("back"); card.classList.add("drag"); card.style.zIndex = 5;
      try { card.setPointerCapture(id); } catch (_) {}
      // How far left the card travels before a release sends it: progress 1.
      var r0 = card.getBoundingClientRect();
      reach = Math.max(40, r0.left + r0.width * 0.35);
      baseLeft = r0.left; baseWidth = r0.width;
      card._base = { left: r0.left, width: r0.width, top: r0.top, height: r0.height };
      // A selected card takes every selected card with it, itself first.
      group = [card];
      if (card.classList.contains("selected")) {
        Array.prototype.forEach.call(grid.querySelectorAll(".card.selected"), function (c) {
          if (c !== card && !c.classList.contains("sending") && !c.classList.contains("sent") && !c.classList.contains("queued") && !c.classList.contains("stacked")) group.push(c);
        });
      }
      gathered = false;
      if (group.length > 1) gatherTimer = setTimeout(function () { if (active) gather(false); }, 120);
      // The Mac's peek is the stack from its very first message.
      peekStart(card, group.length);
    });
    card.addEventListener("pointermove", function (e) {
      if (!active || e.pointerId !== id) return;
      dx = e.clientX - startX; dy = e.clientY - startY;
      if (!gathered && group.length > 1 && (Math.abs(dx) > 6 || Math.abs(dy) > 6)) gather(false);
      samples.push({ x: e.clientX, y: e.clientY, t: e.timeStamp }); if (samples.length > 6) samples.shift();
      var p = clamp01(-dx / reach);
      var move = "translate(" + dx + "px," + dy * 0.4 + "px)", tilt = " rotate(" + dx / 25 + "deg)", t = move + tilt;
      if (!calm()) {
        // Near the edge (s) the card changes shape for the effect; crossing it (c), it fades.
        var left = baseLeft + dx;
        var s = clamp01((24 - left) / (24 + baseWidth * 0.5)), c = clamp01(-left / (baseWidth * 0.6));
        var fade = 0.5, light = 0.85;
        if (effect === "liquid") {
          // A drop: rounder, wider and flatter as the edge pulls it.
          t = move + (s > 0 ? " scale(" + (1 + 0.22 * s).toFixed(3) + "," + (1 - 0.16 * s).toFixed(3) + ")" : "");
          card.classList.toggle("blob", s > 0.15); light = 0.75;
        } else if (effect === "wormhole") {
          // Drawn toward the ring: turning -18° × p and shrinking to .84 about its own centre.
          t = move + " rotate(" + (-18 * p).toFixed(2) + "deg) scale(" + (1 - 0.16 * p).toFixed(3) + ")";
          fade = 0.6;
        } else if (effect === "beam") {
          t = move; light = 0.95;
        } else if (effect === "plane") {
          // Creases show past p = .45 and the sheet starts to fold, up to 18°.
          var fold = clamp01((p - 0.65) / 0.35);
          t = "perspective(700px) " + move + tilt + " rotateY(" + (-18 * fold).toFixed(1) + "deg)";
          card._fold = 18 * fold; s = clamp01((p - 0.45) / 0.55); light = 0.8;
        } else if (s > 0) {
          t += " scale(" + (1 + 0.08 * s).toFixed(3) + "," + (1 - 0.03 * s).toFixed(3) + ")";
        }
        card.style.opacity = c > 0 ? (1 - fade * c).toFixed(3) : "";
        card._flare.style.opacity = (light * s).toFixed(3);
      }
      card.style.transform = t;
      if (gathered) group.slice(1).forEach(follow);
      glow(p);
      card._angle = effect === "wormhole" && !calm() ? -18 * p : (effect === "liquid" || effect === "beam") && !calm() ? 0 : dx / 25;
      var cardY = card._base.top + card._base.height / 2 + dy * 0.4;
      if (window.DropPortalGL) DropPortalGL.hold(p, cardY);
      if (window.DPCourier) DPCourier.hold(effect, p, card);
      if (peek) peekUpdate(peek.id, "peek-move", p, clamp01(cardY / (innerHeight || 1)));
    });
    function end(e, cancelled) {
      if (!active || e.pointerId !== id) return;
      active = false; card.classList.remove("drag"); clearTimeout(gatherTimer); gatherTimer = null;
      var first = samples[0], last = samples[samples.length - 1];
      var vx = last.t > first.t ? (last.x - first.x) / (last.t - first.t) : 0; // px per ms
      var rect = card.getBoundingClientRect();
      var pastEdge = rect.left < -rect.width * 0.35;
      var flicked = vx < -0.5 && dx < -40;
      var tapped = Math.abs(dx) < 10 && Math.abs(dy) < 10;
      if (!cancelled && wasFailed && tapped) { peekEnd("peek-cancel"); glowOff(); unstack(); springBack(card); upload(card); return; }
      if (!cancelled && tapped) { peekEnd("peek-cancel"); glowOff(); unstack(); springBack(card); card.classList.toggle("selected"); return; }
      // The card's own velocity (it moves 0.4 of the finger's dy) and height, for the Mac's throw.
      var vy = last.t > first.t ? (last.y - first.y) * 0.4 / (last.t - first.t) : 0;
      var release = { vx: Math.round(vx * 1000), vy: Math.round(vy * 1000), exitY: clamp01((rect.top + rect.height / 2) / (innerHeight || 1)), angle: card._angle || 0 };
      if (!cancelled && (pastEdge || flicked)) { if (group.length > 1) gather(true); card._peek = peekCommit(release); flyOut(card, dy, rect, group.slice(1)); }
      else { peekEnd("peek-cancel"); glowOff(); unstack(); springBack(card); }
    }
    card.addEventListener("pointerup", function (e) { end(e, false); });
    card.addEventListener("pointercancel", function (e) { end(e, true); });
  }

  // Behind the top card: x, y, degrees; a fourth card and more hide under the third.
  var STACK_LAYERS = [[7, -6, 3], [-7, -10, -3.5], [4, -14, 2]];
  // A cancel: the card springs home and undoes its effect's shape.
  function springBack(card) {
    card.classList.remove("blob", "stacked", "drag", "gathering", "stacktop");
    card.classList.add("back"); card.style.transform = ""; card.style.zIndex = "";
    card.style.opacity = ""; card._flare.style.opacity = "";
  }

  // One Web Animation on transform and opacity; `done` runs when it ends (or at once without the API).
  function play(node, frames, options, done) {
    if (!node.animate) { if (done) done(); return null; }
    var a = node.animate(frames, options);
    if (done) a.onfinish = done;
    return a;
  }

  // A send: the card leaves through the edge in the chosen effect, the edge
  // answers once it is gone (a flash and, for Portal light and Liquid, a
  // small burst), then the card comes back into the grid (faded in) to show
  // the upload. The upload starts at once.
  function flyOut(card, dy, rect, rest) {
    if (navigator.vibrate) navigator.vibrate(10);
    card.classList.remove("selected");
    // The stack leaves as one; back in the grid, the others wait their turn and go one after
    // another, carrying the same id so the Mac counts them on one card.
    var batchId = card._peek;
    rest = rest || [];
    var stack = rest.filter(function (c) { return c.classList.contains("stacked"); });
    // Off screen until it comes home: a "Sent" before that waits for it (sent()).
    card._away = true; stack.forEach(function (c) { c._away = true; });
    rest.forEach(function (c) {
      c.classList.remove("selected"); c.classList.add("queued"); c._badge.textContent = "Waiting…"; c._batch = batchId;
    });
    function next() { var c = rest.shift(); if (c) upload(c, next); }
    var from = card.style.transform || "", y = dy * 0.4, base = card._base || { left: rect.left, width: rect.width };
    // The same frames for every card of the stack, each from its place in it.
    function along(frames, options) {
      stack.forEach(function (c) {
        play(c, frames.map(function (f) {
          var g = {}, k;
          for (k in f) g[k] = f[k];
          if (f.transform !== undefined) g.transform = c._gather + (f.transform === "none" ? "" : f.transform) + c._layer;
          if (c._hidden && f.opacity !== undefined) g.opacity = 0;
          return g;
        }), options);
      });
    }
    var finished = false;
    function settle(node) {
      // A fill-forwards animation would hold the card off screen.
      if (node.getAnimations) node.getAnimations().forEach(function (a) { a.cancel(); });
      node.classList.remove("blob", "stacked", "drag", "gathering", "stacktop");
      node.style.transition = "none"; node._flare.style.transition = "none";
      node.style.transform = ""; node.style.zIndex = ""; node.style.opacity = "0"; node._flare.style.opacity = "";
      void node.offsetWidth;
      node.style.transition = ""; node._flare.style.transition = "";
      node.classList.add("back"); node.style.opacity = "";
      node._away = false;
      var shown = node._home; node._home = null; if (shown) shown();
    }
    function home() {
      if (finished) return; finished = true;
      settle(card); stack.forEach(settle);
    }
    upload(card, next);
    card.style.opacity = "1";
    // Whatever happens to the animation, the card is back within 1.3 s.
    setTimeout(home, 1300);
    var courier = window.DPCourier && DPCourier.has(effect);
    if (calm() && courier) {
      // A courier under Reduce motion: its sticker beside the card, which fades where it is.
      glowOff();
      DPCourier.sticker(effect, rect);
      play(card, [{ opacity: 1 }, { opacity: 0 }], { duration: 160, easing: EASE.F, fill: "forwards" }, home);
      along([{ opacity: 1 }, { opacity: 0 }], { duration: 160, easing: EASE.F, fill: "forwards" });
      return;
    }
    if (calm()) {
      // Reduce motion: a plain fade where it is, and the edge light fades.
      // Stardust and Lightning: a fade and a scale to .9 over 200 ms, and no flash on the edge.
      var skyCalm = effect === "stardust" || effect === "lightning";
      if (skyCalm) glowOff(); else glowFlash();
      play(card, skyCalm ? [{ opacity: 1, transform: from || "none" }, { opacity: 0, transform: (from || "") + " scale(.9)" }] : [{ opacity: 1 }, { opacity: 0 }],
           { duration: skyCalm ? 200 : 160, easing: EASE.F, fill: "forwards" }, home);
      along([{ opacity: 1 }, { opacity: 0 }], { duration: 160, easing: EASE.F, fill: "forwards" });
      return;
    }
    // No pull-back: the card leaves from exactly where the finger let go
    // (t = 0), on the spec's curve A, and the edge answers when it is gone.
    var kind = effect, start = from || "none";
    if (window.DropPortalGL) DropPortalGL.send();
    // Enough to put the card's right edge past the left edge of the screen.
    var exitX = -(base.left + base.width + 40);
    function impact() { glowFlash(); impactBurst(rect); }
    if (courier) {
      // A courier (WebCourierEffect.swift) takes a drawn copy of the card and leaves through the edge.
      glowOff();
      play(card, [{ opacity: 1 }, { opacity: 0 }], { duration: 60, fill: "forwards" });
      along([{ opacity: 1 }, { opacity: 0 }], { duration: 60, fill: "forwards" });
      DPCourier.leap(kind, card, rect, function () { setTimeout(home, 120); });
    } else if (kind === "liquid") {
      // Drawn out into a thin neck into the edge: 1.18 × .88 → 1.80 × .18 in 260 ms.
      card.classList.add("blob"); card._flare.style.opacity = "1";
      var neck = -(base.left + base.width * 0.3);
      var drop = [{ transform: start + " scale(1.18,.88)", opacity: 1 },
                  { transform: "translate(" + neck + "px," + y + "px) scale(1.55,.35)", opacity: 0.95, offset: 0.7 },
                  { transform: "translate(" + exitX + "px," + y + "px) scale(1.8,.18)", opacity: 0 }];
      along(drop, { duration: 260, easing: EASE.A, fill: "forwards" });
      play(card, drop, { duration: 260, easing: EASE.A, fill: "forwards" }, function () { impact(); setTimeout(home, 460); });
    } else if (kind === "wormhole") {
      // Into the ring: to -120° and .08 in 240 ms; the ring flashes and closes.
      card._flare.style.opacity = "1";
      var hole = [{ transform: start, opacity: 1 },
                  { transform: "translate(" + exitX + "px," + y + "px) rotate(-120deg) scale(.08)", opacity: 0 }];
      along(hole, { duration: 240, easing: EASE.A, fill: "forwards" });
      play(card, hole, { duration: 240, easing: EASE.A, fill: "forwards" }, function () { impact(); setTimeout(home, 300); });
    } else if (kind === "beam") {
      // Nine strips stream off 12 ms apart, top first; the stack under it slides off with them.
      along([{ transform: start, opacity: 1 }, { opacity: 1, offset: 0.8 },
             { transform: "translate(" + exitX + "px," + y + "px)", opacity: 0 }], { duration: 200, easing: EASE.A, fill: "forwards" });
      beamOut(card, rect, function () { impact(); setTimeout(home, 220); });
    } else if (kind === "plane") {
      // The sheet folds shut (18° → 68° in 100 ms) and turns into a plane that loops and leaves.
      var hinge = card._fold || 0;
      var fold = [{ transform: start, opacity: 1 },
                  { transform: start + " rotateY(" + (-68 + hinge) + "deg)", opacity: 1, offset: 0.6 },
                  { transform: start + " rotateY(" + (-68 + hinge) + "deg) scale(.6)", opacity: 0 }];
      along(fold, { duration: 100, easing: EASE.O, fill: "forwards" });
      play(card, fold, { duration: 100, easing: EASE.O, fill: "forwards" });
      planeOut(rect, y, function () { impact(); setTimeout(home, 180); });
    } else if ((kind === "stardust" || kind === "lightning") && window.DropPortalSky) {
      // WebSkyEffect.swift: the card dissolves into grains, or rides one strike off the edge.
      along([{ transform: start, opacity: 1 }, { transform: "translate(" + exitX + "px," + y + "px)", opacity: 0 }], { duration: 250, easing: EASE.A, fill: "forwards" });
      if (kind === "stardust") DropPortalSky.stardust(card, function () { impact(); setTimeout(home, 480); });
      // Lightning's one bright beat is its own flash (under the cap): the edge only fades.
      else {
        // The card rides the bolt off the edge: still for the leader, then away on curve A, gone by 250 ms.
        play(card, [{ transform: start, opacity: 1 }, { transform: start, opacity: 1, offset: 0.24, easing: "cubic-bezier(.3,0,.8,.15)" },
                    { transform: "translate(" + exitX + "px," + y + "px)", opacity: 0 }], { duration: 250, fill: "forwards" });
        DropPortalSky.lightning(card, { start: start, exitX: exitX, y: y }, function () { glowOff(); if (window.DropPortalGL) DropPortalGL.flash(); setTimeout(home, 200); });
      }
    } else {
      // Portal light: through the edge in 220 ms, fading only in the last 60.
      card._flare.style.opacity = "1";
      var light = [{ transform: start, opacity: 1 }, { opacity: 1, offset: 0.73 },
                   { transform: "translate(" + exitX + "px," + y + "px) scale(1.08,.97)", opacity: 0 }];
      along(light, { duration: 220, easing: EASE.A, fill: "forwards" });
      play(card, light, { duration: 220, easing: EASE.A, fill: "forwards" }, function () { impact(); setTimeout(home, 400); });
    }
  }

  // The same nine slices as the Mac rebuilds, cut once from a clone of the card.
  var BEAM_STRIPS = 9;
  function beamOut(card, rect, done) {
    var h = rect.height / BEAM_STRIPS, made = [];
    card.style.opacity = "0";
    for (var i = 0; i < BEAM_STRIPS; i++) {
      var strip = el("div", "strip");
      strip.style.left = rect.left + "px"; strip.style.top = (rect.top + i * h) + "px";
      strip.style.width = rect.width + "px"; strip.style.height = Math.ceil(h + 0.5) + "px";
      var copy = card.cloneNode(true);
      copy.classList.remove("drag", "back", "blob");
      copy.style.cssText = "width:" + rect.width + "px;height:" + rect.height + "px;top:" + (-i * h) + "px;";
      var flare = copy.querySelector(".flare"); if (flare) flare.style.opacity = "0.9";
      strip.appendChild(copy);
      document.body.appendChild(strip);
      made.push(strip);
      play(strip, [{ transform: "translate3d(0,0,0)", opacity: 1 }, { opacity: 1, offset: 0.8 },
                   { transform: "translate3d(" + -(rect.right + 40) + "px,0,0)", opacity: 0 }],
           { duration: 200, delay: i * 12, easing: EASE.A, fill: "forwards" });
    }
    // The last strip is gone at 296 ms.
    setTimeout(function () { made.forEach(function (n) { n.remove(); }); done(); }, 200 + (BEAM_STRIPS - 1) * 12);
  }

  var PLANE_SVG = '<svg viewBox="0 0 76 46" aria-hidden="true"><path d="M0 23 L76 0 L48 46 Z" fill="#f5f7ff"/><path d="M0 23 L76 0 L36 30 Z" fill="#cdd6ec"/><path d="M36 30 L48 46 L42 28 Z" fill="#98a5c4"/></svg>';
  // The plane appears as the sheet closes (60–100 ms), loops once like the
  // Mac's, then leaves through the left edge on curve A, nose following its
  // path; a short contrail of dashes behind it. Transform and opacity only.
  function planeOut(rect, dy, done) {
    var plane = el("div", "plane"), cx = rect.left + rect.width / 2, cy = rect.top + rect.height / 2;
    plane.innerHTML = PLANE_SVG;
    plane.style.opacity = "0";
    document.body.appendChild(plane);
    var t0 = performance.now(), FOLD = 100, LOOP = 380, EXIT = 220, R = Math.min(70, rect.width * 0.4);
    var exitBy = cx + 180, dash = 0, last = null;
    function ease(u) { return u * u * (3 - 2 * u); }
    function accel(u) { return Math.pow(u, 2.2); }
    function at(ms) {
      if (ms <= FOLD) return { x: cx, y: cy };
      if (ms <= FOLD + LOOP) {
        // Once round: left, up and over, back where it started.
        var phi = 2 * Math.PI * ease((ms - FOLD) / LOOP);
        return { x: cx - R * Math.sin(phi), y: cy - R + R * Math.cos(phi) };
      }
      var u = Math.min(1, (ms - FOLD - LOOP) / EXIT);
      return { x: cx - exitBy * accel(u), y: cy - 24 * u };
    }
    (function step(now) {
      var ms = now - t0, p = at(ms), q = at(ms + 12);
      var ang = Math.atan2(q.y - p.y, q.x - p.x) - Math.PI;
      if (!(Math.abs(q.x - p.x) + Math.abs(q.y - p.y) > 0.01)) ang = 0;
      plane.style.opacity = Math.min(1, Math.max(0, (ms - 60) / 40)).toFixed(3);
      plane.style.transform = "translate(" + p.x.toFixed(1) + "px," + p.y.toFixed(1) + "px) rotate(" + ang.toFixed(3) + "rad)";
      if (ms > FOLD && last && (dash++ % 3 === 0)) {
        var tail = Math.atan2(last.y - p.y, last.x - p.x);
        spawn({ kind: "dash", x: p.x + Math.cos(tail) * 46, y: p.y + Math.sin(tail) * 46, vx: 0, vy: 0, r: 1.8, len: 10, ang: tail, life: 360, c: TONES.glow.join(",") });
      }
      last = p;
      if (ms < FOLD + LOOP + EXIT) requestAnimationFrame(step);
      else { plane.remove(); done(); }
    })(t0);
  }

  // Screen Wake Lock while anything is being sent: iOS suspends a page whose
  // screen locks, and the transfer with it.
  var busyCount = 0, wakeLock = null, keep = document.getElementById("keep");
  function holdAwake() {
    if (!busyCount || wakeLock || document.hidden || !navigator.wakeLock) return;
    wakeLock = "pending";
    navigator.wakeLock.request("screen").then(function (lock) {
      if (!busyCount || (wakeLock && wakeLock !== "pending")) { lock.release(); if (!busyCount) wakeLock = null; return; }
      wakeLock = lock;
      lock.addEventListener("release", function () { if (wakeLock === lock) wakeLock = null; });
    }, function () { wakeLock = null; });
  }
  function busy(delta) {
    busyCount = Math.max(0, busyCount + delta);
    keep.hidden = !busyCount;
    if (busyCount) return holdAwake();
    if (wakeLock && wakeLock !== "pending") wakeLock.release();
    wakeLock = null;
  }
  document.addEventListener("visibilitychange", function () { if (!document.hidden) holdAwake(); });

  function sent(card) {
    card.classList.add("sent"); card._badge.textContent = "Sent";
    var named = !!(card._file && card._file.name);
    loadRecentSoon();
    function show() {
      if (named) kineticName(card._badge, card._file.name);
      setTimeout(function () { card.classList.add("gone"); setTimeout(function () { remove(card); }, 320); }, named ? 1150 : 900);
    }
    // Still flying (a quick upload): the name plays once the card is back in view, at most 3 s later.
    if (!card._away) return show();
    card._home = show;
    setTimeout(function () { var go = card._home; card._home = null; if (go) go(); }, 3000);
  }

  // Kinetic filename, as on the Mac's landed card (LandingTouches.swift): the
  // name under "Sent" comes in letter by letter, blur to sharp and rising a
  // few px, stagger min(25, 300 / n) ms, each letter 320 ms, all in by 650 ms.
  // Cut in the middle first, keeping the extension; VoiceOver reads the full
  // name once from a hidden copy, never the letters. Reduced motion: a fade.
  var kinetic = true, measureCtx = null;
  function textWidth(text, font) {
    if (!measureCtx) measureCtx = document.createElement("canvas").getContext("2d");
    measureCtx.font = font;
    return measureCtx.measureText(text).width;
  }
  function splitExt(name) {
    var dot = name.lastIndexOf(".");
    if (dot <= 0) return [name, ""];
    var ext = name.slice(dot);
    return (ext.length >= 2 && ext.length <= 9 && ext.indexOf(" ") < 0) ? [name.slice(0, dot), ext] : [name, ""];
  }
  function cutName(name, max, font) {
    if (textWidth(name, font) <= max) return name;
    var parts = splitExt(name), base = Array.from(parts[0]), ext = parts[1];
    for (var keep = base.length - 1; keep >= 0; keep--) {
      var head = Math.floor((keep + 1) / 2) + (keep > 6 ? 1 : 0), tail = Math.max(0, keep - head);
      var cut = base.slice(0, Math.min(head, keep)).join("").replace(/\s+$/, "") + "\u2026" + (tail ? base.slice(-tail).join("") : "").replace(/^\s+/, "") + ext;
      if (textWidth(cut, font) <= max) return cut;
    }
    var short = Array.from("\u2026" + ext);
    while (short.length > 1 && textWidth(short.join(""), font) > max) short.pop();
    return short.join("");
  }
  function kineticName(box, name) {
    var line = el("span", "kname"), sr = el("span", "sr"), letters = el("span");
    sr.textContent = name; letters.setAttribute("aria-hidden", "true");
    line.appendChild(sr); line.appendChild(letters); box.appendChild(line);
    var cs = getComputedStyle(line);
    var text = cutName(name, Math.max(40, box.clientWidth - 28), cs.fontWeight + " " + cs.fontSize + " " + cs.fontFamily);
    if (!kinetic || calm() || !letters.animate) {
      letters.textContent = text;
      if (calm() && letters.animate) letters.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200, fill: "backwards" });
      return;
    }
    var chars = Array.from(text), n = chars.length, stagger = Math.min(25, 300 / n);
    var ext = splitExt(text)[1], extAt = ext ? n - Array.from(ext).length : n;
    chars.forEach(function (ch, i) {
      var s = el("span", i >= extAt ? "kl ext" : "kl"); s.textContent = ch; letters.appendChild(s);
      s.animate([
        { opacity: 0, filter: "blur(3px)", transform: "translate(2px,4.5px)", offset: 0 },
        { opacity: 1, offset: 0.7 },
        { opacity: 1, filter: "blur(0px)", transform: "translate(0,0)", offset: 1 }
      ], { duration: 320, delay: i * stagger, easing: "cubic-bezier(.2,.9,.3,1)", fill: "backwards" });
    });
  }

  // Smaller files: photos are redrawn at most 2560 px on the long edge as JPEG
  // 0.85 before they leave; the original goes when that is not smaller or the
  // browser cannot decode it (HEIC outside Safari). Videos go as they are.
  var shrinkBox = document.getElementById("shrink"), shrinkHint = document.getElementById("shrinkHint");
  var SHRINK_EDGE = 2560, SHRINK_QUALITY = 0.85;
  try { shrinkBox.checked = localStorage.getItem("dropportal.shrink") === "1"; } catch (_) {}
  shrinkHint.hidden = !shrinkBox.checked;
  shrinkBox.addEventListener("change", function () {
    shrinkHint.hidden = !shrinkBox.checked;
    try { localStorage.setItem("dropportal.shrink", shrinkBox.checked ? "1" : "0"); } catch (_) {}
  });
  function shrinkable(file) { return /^image\/(jpeg|png|webp|heic|heif|bmp|tiff)$/i.test(file.type || "") && file.size > 300e3; }
  function shrink(file, done) {
    var url = URL.createObjectURL(file), img = new Image(), over = false;
    function finish(result) { if (over) return; over = true; URL.revokeObjectURL(url); done(result); }
    img.onerror = function () { finish(null); };
    img.onload = function () {
      var w = img.naturalWidth, h = img.naturalHeight;
      if (!w || !h) return finish(null);
      var scale = Math.min(1, SHRINK_EDGE / Math.max(w, h));
      var c = el("canvas"); c.width = Math.max(1, Math.round(w * scale)); c.height = Math.max(1, Math.round(h * scale));
      try {
        var ctx = c.getContext("2d");
        ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, c.width, c.height);
        ctx.drawImage(img, 0, 0, c.width, c.height);
        c.toBlob(function (blob) {
          c.width = c.height = 0;
          if (!blob || blob.size >= file.size) return finish(null);
          var name = (file.name || "photo").replace(/\.[^.]*$/, "") + ".jpg";
          finish(new File([blob], name, { type: "image/jpeg" }));
        }, "image/jpeg", SHRINK_QUALITY);
      } catch (_) { finish(null); }
    };
    img.src = url;
  }

  function upload(card, then) {
    if (shrinkBox.checked && !card._shrunk && shrinkable(card._file)) {
      card._shrunk = true;
      card.classList.add("sending");
      return shrink(card._file, function (small) {
        if (small) {
          var saved = el("div", "saved"); saved.textContent = "\u2212" + human(card._file.size - small.size);
          card.appendChild(saved);
          card._file = small;
        }
        upload(card, then);
      });
    }
    var file = card._file;
    // Only the flick that made the peek carries it; a retry lands the plain way.
    var peekId = card._peek; card._peek = null;
    var batchId = card._batch; card._batch = null;
    card.classList.remove("queued");
    function failed(message) { if (peekId) peekEnd("peek-cancel", peekId); fail(card, message); }
    card.classList.add("sending"); card._fill.style.width = "0";
    busy(1);
    var xhr = new XMLHttpRequest(), done = false, stall = null;
    function finish() {
      if (done) return false;
      done = true; clearTimeout(stall); card.classList.remove("sending"); busy(-1);
      if (then) setTimeout(then, 0);
      return true;
    }
    function watch() {
      clearTimeout(stall);
      stall = setTimeout(function () { if (finish()) { xhr.abort(); failed(UNREACHABLE); } }, STALL_TIMEOUT);
    }
    xhr.open("POST", "/upload");
    xhr.setRequestHeader("X-DropPortal-Token", token);
    xhr.setRequestHeader("X-DropPortal-Name", encodeURIComponent(file.name || "file"));
    if (peekId || batchId) xhr.setRequestHeader("X-DropPortal-Peek", peekId || batchId);
    xhr.upload.onprogress = function (e) {
      watch();
      if (!e.lengthComputable) return;
      card._fill.style.width = (100 * e.loaded / e.total) + "%";
      if (peekId) peekUpdate(peekId, "peek-progress", e.total ? e.loaded / e.total : 0);
    };
    xhr.onload = function () {
      if (!finish()) return;
      if (xhr.status === 200) {
        if (peekId) peekEnd(null, peekId);
        sent(card);
      } else {
        failed(xhr.status === 403 ? "Pairing changed. Scan the QR code on your Mac again."
                 : xhr.status === 413 ? "Too large (2 GB max)."
                 : "Your Mac could not save it. Tap to retry.");
      }
    };
    xhr.onerror = function () { if (finish()) failed(UNREACHABLE); };
    watch();
    xhr.send(file);
  }

  function fail(card, message) { card.classList.add("failed"); card._badge.textContent = message; }
  function remove(card) { if (card._url) URL.revokeObjectURL(card._url); card.remove(); updateEmpty(); }

  var text = document.getElementById("text"), textStatus = document.getElementById("textStatus");
  function sendText() {
    var value = text.value;
    if (!value) { textStatus.textContent = "Paste something first."; return; }
    textStatus.textContent = "Sending…";
    var xhr = new XMLHttpRequest();
    xhr.timeout = STALL_TIMEOUT;
    xhr.open("POST", "/text");
    xhr.setRequestHeader("X-DropPortal-Token", token);
    xhr.setRequestHeader("Content-Type", "text/plain; charset=utf-8");
    xhr.onload = function () {
      if (xhr.status === 200) {
        var link = false; try { link = JSON.parse(xhr.responseText).link === "1"; } catch (_) {}
        textStatus.textContent = link ? "Opened on your Mac, and on its clipboard." : "On your Mac's clipboard."; text.value = "";
      }
      else textStatus.textContent = xhr.status === 403 ? "Pairing changed. Scan the QR code again."
                                  : xhr.status === 413 ? "Too long (1 MB max)." : "Your Mac could not take it. Try again.";
    };
    xhr.onerror = xhr.ontimeout = function () { textStatus.textContent = "Mac not reachable - same Wi-Fi?"; };
    xhr.send(value);
  }
  document.getElementById("sendText").addEventListener("click", sendText);

  // From the Mac, over the peek socket: a file to save, or the Mac's clipboard.
  var inbox = document.getElementById("inbox"), inboxList = document.getElementById("inboxList");
  var shareFiles = false;
  try { shareFiles = !!(navigator.canShare && navigator.canShare({ files: [new File(["x"], "x.txt", { type: "text/plain" })] })); } catch (_) {}
  function human(n) {
    var u = ["bytes", "KB", "MB", "GB"], i = 0;
    while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
    return (i ? n.toFixed(1) : n) + " " + u[i];
  }
  function inboxAdd(box) {
    inboxList.insertBefore(box, inboxList.firstChild);
    while (inboxList.children.length > 20) inboxList.removeChild(inboxList.lastChild);
    inbox.hidden = false;
    if (navigator.vibrate) navigator.vibrate(10);
  }
  function incoming(m) {
    if (typeof m.id !== "string" || !/^[a-z0-9]{1,64}$/.test(m.id)) return;
    var name = String(m.name || "file"), href = "/download/" + m.id + "?t=" + encodeURIComponent(token);
    var box = el("div", "in arrive");
    if (m.kind === "image") { var img = el("img"); img.alt = name; img.src = href; box.appendChild(img); }
    var row = el("div", "row");
    var info = el("span", "status"); info.textContent = name + " · " + human(Number(m.size) || 0); row.appendChild(info);
    var save = el("a", "btn primary"); save.textContent = "Save"; save.href = href; save.setAttribute("download", name);
    row.appendChild(save); box.appendChild(row);
    if (m.kind === "image" && !shareFiles) { var hint = el("div", "hint"); hint.textContent = "Or touch and hold the picture to save it to Photos."; box.appendChild(hint); }
    // The share sheet needs the file in hand at the tap, so it is fetched now (up to 100 MB).
    if (shareFiles && (Number(m.size) || 0) <= 100e6) {
      fetch(href).then(function (r) { return r.ok ? r.blob() : null; }).then(function (blob) {
        if (!blob) return;
        var file = new File([blob], name, { type: blob.type });
        save.textContent = "Save or share";
        save.addEventListener("click", function (e) {
          e.preventDefault();
          navigator.share({ files: [file] }).catch(function () {});
        });
      }, function () {});
    }
    inboxAdd(box);
    loadRecentSoon();
  }
  function clipboard(value) {
    var box = el("div", "in");
    var body = el("div", "clip"); body.textContent = value; box.appendChild(body);
    var row = el("div", "row");
    var status = el("span", "status"); status.textContent = "Clipboard from your Mac"; row.appendChild(status);
    var copy = el("button", "btn primary"); copy.textContent = "Copy"; row.appendChild(copy);
    box.appendChild(row);
    copy.addEventListener("click", function () {
      function done(ok) { status.textContent = ok ? "Copied." : "Touch and hold the text to copy it."; }
      if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(value).then(function () { done(true); }, function () { done(false); }); return; }
      // Plain http has no Clipboard API: copy from a hidden text field instead.
      var ta = el("textarea"); ta.value = value; ta.style.cssText = "position:fixed;top:0;left:0;opacity:0;font-size:16px";
      document.body.appendChild(ta); ta.focus(); ta.select(); ta.setSelectionRange(0, value.length);
      var ok = false; try { ok = document.execCommand("copy"); } catch (_) {}
      ta.remove(); done(ok);
    });
    inboxAdd(box);
  }

  // Recent: the Mac's last transfers both ways. A tap downloads one again while
  // it is still on the Mac; Send again offers a file from the Mac afresh (a
  // folder is zipped again), and it arrives under From your Mac.
  var recent = document.getElementById("recent"), recentList = document.getElementById("recentList");
  var RECENT_MAX = 10, recentTimer = null;
  function ago(ms) {
    var s = Math.max(0, (Date.now() - Number(ms)) / 1000);
    if (s < 60) return "just now";
    if (s < 3600) return Math.floor(s / 60) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago";
    return Math.floor(s / 86400) + " d ago";
  }
  function loadRecentSoon() { clearTimeout(recentTimer); recentTimer = setTimeout(loadRecent, 400); }
  function loadRecent() {
    if (!token || document.hidden) return;
    var xhr = new XMLHttpRequest();
    xhr.timeout = 10000;
    xhr.open("GET", "/history?t=" + encodeURIComponent(token));
    xhr.onload = function () {
      if (xhr.status !== 200) return;
      var items = null; try { items = JSON.parse(xhr.responseText).items; } catch (_) {}
      if (Array.isArray(items)) renderRecent(items);
    };
    xhr.send();
  }
  function renderRecent(items) {
    recentList.textContent = "";
    var q = "?t=" + encodeURIComponent(token);
    items.slice(0, RECENT_MAX).forEach(function (it) {
      if (!it || typeof it.id !== "string" || !/^[0-9a-f]{1,32}$/.test(it.id)) return;
      var name = String(it.name || "file"), base = "/history/" + it.id, folder = it.kind === "folder";
      var row = el(folder ? "div" : "a", "rec");
      if (!folder) { row.href = base + q; row.setAttribute("download", name); }
      var thumb = el("div", "rthumb");
      if (it.kind === "image") { var img = el("img"); img.alt = ""; img.loading = "lazy"; img.src = base + "/thumb" + q; thumb.appendChild(img); }
      else thumb.textContent = folder ? "ZIP" : (name.indexOf(".") > 0 ? name.split(".").pop() : "FILE").slice(0, 4).toUpperCase();
      row.appendChild(thumb);
      var words = el("div", "rtext");
      var n = el("div", "rname"); n.textContent = name; words.appendChild(n);
      var meta = el("div", "rmeta");
      meta.textContent = (it.dir === "in" ? "Sent to your Mac" : "From your Mac") + " \u00b7 " + human(Number(it.size) || 0) + " \u00b7 " + ago(it.time);
      words.appendChild(meta); row.appendChild(words);
      if (it.dir === "out") {
        var again = el("button", "btn small"); again.textContent = "Send again"; again.type = "button";
        again.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); resend(it.id, again); });
        row.appendChild(again);
      }
      recentList.appendChild(row);
    });
    recent.hidden = !recentList.children.length;
  }
  function resend(id, button) {
    button.disabled = true; button.textContent = "Sending…";
    var xhr = new XMLHttpRequest();
    xhr.timeout = STALL_TIMEOUT;
    xhr.open("POST", "/history/" + id + "/send");
    xhr.setRequestHeader("X-DropPortal-Token", token);
    xhr.onload = function () {
      button.disabled = false;
      button.textContent = xhr.status === 200 ? "Asked" : xhr.status === 404 ? "Gone" : "Try again";
      if (xhr.status === 404) loadRecentSoon();
    };
    xhr.onerror = xhr.ontimeout = function () { button.disabled = false; button.textContent = "Try again"; };
    xhr.send();
  }
  document.addEventListener("visibilitychange", function () { if (!document.hidden) loadRecentSoon(); });

  updateEmpty();
  connect();
  loadRecent();
})();
</script>
</body>
</html>
"""#
}
