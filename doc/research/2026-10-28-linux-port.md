# The Linux port for KATANA Gen 3

Looked at 2026-10-28: <https://github.com/Shesherd/BOSS-TONE-STUDIO-GEN-3-EXTENDED-FOR-LINUX>, a fork of Brian Jia's
port, which runs Roland's Gen 3 editor web app on Linux with pywebview, Flask and mido.

- The original port's `Dockerfile.prepare` downloaded Roland's Windows installer at build time and patched the web app
  (`html-patches/html-katana-gen-3.patch`).
- The fork commits Roland's web app — modified — to its public repository (`pywebview/html/`) and ships it in a `.deb`.
- Its changes to Roland's files, from its repository and README: a rewritten `native.js` transport to its Python server,
  MIDI sent in batches of five (changing the editor's timing), "virtual" patch slots beyond the hardware's, a Librarian
  limit raised from 15 to 25 patches, a changed amp identity check, BOSS TONE EXCHANGE redirected to the browser, and
  extra CSS themes and tip pages.

This project differs on purpose: Roland's files are neither modified nor committed; the build takes them from Roland's
own download, and the page is adapted only through one script added to the served response (see
[ADR-0002](../decisions/ADR-0002-local-http-bridge-speaking-native-js.md) and
[ADR-0008](../decisions/ADR-0008-standalone-bundle-from-rolands-installer.md)).
