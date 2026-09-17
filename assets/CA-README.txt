Lootryx TLS trust roots

cacert.pem is the unmodified Mozilla CA certificate bundle distributed by curl.
Source: https://curl.se/ca/cacert.pem
Published checksum: https://curl.se/ca/cacert.pem.sha256
Bundle date: 2026-08-13
Verified SHA-256: f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9

The certificate bundle is licensed under MPL 2.0. See CA-LICENSE.txt and
https://www.mozilla.org/en-US/MPL/2.0/ . Upstream source and conversion information:
https://curl.se/docs/caextract.html

This file is shipped as data. The addon never downloads or updates it while running.
Review refreshed Mozilla/curl roots and verify their published checksum when preparing
new addon releases. Runtime verification checks the CA chain and the requested host's
Subject Alternative Name before any HTTP request headers or body are sent.
